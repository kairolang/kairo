/// --- The Kairo Project -------------------------- Config/Invocation.k --- ///
///
///   The canonical, strongly-typed representation of one compiler run.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Command::ParsedArgs::*;
import Command::Command::*;
import Command::FlagRegistry::*;
import Diagnostic::Engine::*;
import Config::Language::*;
import Config::Diagnostic::*;
import Config::Preprocessor::*;
import Config::CodeGen::*;
import Config::Frontend::*;
import Config::Target::*;
import Config::Linker::*;

///
/// \class CompilerInvocation
///
/// \brief The canonical, strongly-typed representation of one compiler run.
///
/// Built once from ParsedArgs at driver startup via from_args().  After that
/// point nothing in the pipeline reads raw string flag keys - all options are
/// accessed through the typed sub-option structs below.
///
/// All sub-option types are value types, so CompilerInvocation is copyable and
/// can be freely passed around by value or reference.
///
/// \par Construction is independent of CompilerInstance
///      from_args(argc, argv, diag) is a static factory: it owns the whole argv
///      -> options path and never touches a CompilerInstance. A programmatic
///      caller fills the fields directly and hands the result to
///      CompilerInstance(inv) instead of serialising options back into flag
///      strings for the CLI parser to re-parse. Mirrors clang's
///      CompilerInvocation::CreateFromArgs / CompilerInstance::setInvocation.
///
class CompilerInvocation {
    // -- sub-option structs (one per subsystem) ----------------------------
    pub var lang:     LangOptions;
    pub var diag:     DiagnosticOptions;
    pub var pp:       PreprocessorOptions;
    pub var codegen:  CodeGenOptions;
    pub var frontend: FrontendOptions;
    pub var target:   TargetOptions;
    pub var linker:   LinkerOptions;
    // -- input files & search paths ----------------------------------------
    pub var working_dir:    string = "";
    pub var input_encoding: string = "utf-8";
    pub var input_files:    vec::<string>;
    pub var include_dirs:   vec::<string>;
    pub var ffi_includes:   vec::<string>;
    pub var cxx_includes:   vec::<string>;
    pub var macro_paths:    vec::<string>;
    // -- link paths & libraries --------------------------------------------
    pub var lib_dirs:       vec::<string>;
    pub var link_libs:      vec::<string>;

    // -- provenance --------------------------------------------------------

    /// \brief the raw parsed CLI this invocation came from.
    ///
    /// \details Kept because a handful of flags have no typed home: --help,
    ///          --version, --explain and the --print-* info queries are
    ///          driver-identity questions, not compilation options.
    ///          CompilerInstance answers them off this.
    ///
    ///          EMPTY on the programmatic path, and that is well-defined: every
    ///          ParsedArgs getter returns the zero value for a key it does not
    ///          hold, so an invocation built by hand answers "not asked" to all
    ///          of them.
    pub var args: ParsedArgs;

    /// \brief whether this invocation is usable.
    ///
    /// \details False ONLY when argv parsing failed (see from_args below). A
    ///          hand-built invocation is ok by construction   there is no flag
    ///          syntax to get wrong   so the default is true and a programmatic
    ///          caller never has to set it.
    pub var ok: bool = true;

    static fn from_args(args: ref!(ParsedArgs)) -> CompilerInvocation {
        var inv = CompilerInvocation();
        (inv.args)     = args;
        (inv.ok)       = args.ok;
        (inv.lang)     = LangOptions::from_args(args);
        (inv.diag)     = DiagnosticOptions::from_args(args);
        (inv.pp)       = PreprocessorOptions::from_args(args);
        (inv.codegen)  = CodeGenOptions::from_args(args);
        (inv.frontend) = FrontendOptions::from_args(args);
        (inv.target)   = TargetOptions::from_args(args);
        (inv.linker)   = LinkerOptions::from_args(args);

        (inv.input_files)    = (args.files);
        (inv.working_dir)    = (args.get_string("working-dir"));
        (inv.input_encoding) = (args.get_string("input-encoding"));

        for s in (args.get_list("include-dirs"))      { (inv.include_dirs.push_back(s)); }
        for s in (args.get_list("ffi-include"))       { (inv.ffi_includes.push_back(s)); }
        for s in (args.get_list("cxx-include"))       { (inv.cxx_includes.push_back(s)); }
        for s in (args.get_list("macro-search-path")) { (inv.macro_paths.push_back(s));  }
        for s in (args.get_list("lib-dirs"))          { (inv.lib_dirs.push_back(s));     }
        for s in (args.get_list("link-libs"))         { (inv.link_libs.push_back(s));    }
        return inv;
    }

    /// \brief the whole argv -> options path, with no CompilerInstance in it.
    ///
    /// \details Defines the flag table, parses \p argv against it, and lowers
    ///          the result into typed options. This is ALL of it   the driver's
    ///          constructor is a caller of this function, not a second copy of
    ///          it.
    ///
    /// \par Why a DiagEngine parameter rather than an error list
    ///      Flag errors are diagnostics like any other: Command reports them
    ///      through DiagCode/DiagBuilder so `-I` with no argument renders the
    ///      same way an unknown identifier does. Handing back a private string
    ///      list would fork that formatting, and the engine is not owned by the
    ///      CompilerInstance anyway   it is created before one exists and can
    ///      be created by a caller that never builds one. So the engine comes
    ///      in, and \c ok comes out for callers that want a bool.
    ///
    /// \param diag  where flag errors are reported. MUST NOT be null   Command
    ///              reports through it unconditionally. A caller with no engine
    ///              of its own can stand up a throwaway DiagEngine and read the
    ///              messages back through a consumer.
    ///
    /// \return the invocation. On a parse failure \c ok is false, \c args holds
    ///         whatever was parsed before the error, and every typed sub-option
    ///         is left at its default   the same shape the driver has always
    ///         had on a bad command line.
    static fn from_args(
        argc: i32,
        argv: *(*kairo::std::Legacy::char),
        diag: *DiagEngine
    ) -> CompilerInvocation {
        var inv = CompilerInvocation();

        if diag == &null {
            (inv.ok) = false;
            return inv;
        }

        var cmd = std::create::<Command>(argc, argv, diag);
        finally { std::destroy(cmd); }

        register_kairo_flags(cmd);
        var parsed = cmd->parse();

        if parsed.ok {
            inv = CompilerInvocation::from_args(parsed);
        } else {
            (inv.args) = parsed;
            (inv.ok)   = false;
        }

        return inv;
    }
}