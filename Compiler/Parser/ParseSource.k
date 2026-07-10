/// --- The Kairo Project --------------------- Compiler/Parser/ParseSource.k --- ///
///
///   \brief Parse Kairo source from an in-memory string.
///
///   \detail
///     Self-contained frontend harness: owns every subsystem needed to turn a
///     string into a TranslationUnit (thread pool, VFM, diagnostics, source
///     manager, token cache, hoisted-scope index). No filesystem access, no
///     preprocessing   imports and macro expansions in the snippet are NOT
///     resolved. Intended for tests, tooling, and REPL-style consumers.
///
///     Usage:
///       var src = parse_source("fn main() { return 0; }");
///       finally { std::destroy(src); }
///       if src->ok() {
///           var tu = src->tu();
///           // walk tu->program ...
///       }
///
///     This is the *standalone* string-parse entry point (cf. Clang's
///     buildASTFromCode). The in-context variant used by quasi-quoting  
///     parsing a snippet into an EXISTING ASTContext   is a separate,
///     lighter path and does not live here.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Threading::ThreadPool::*;
import Support::FileIO::VirtualFileManager::*;
import Support::FileIO::Path::*;
import Diagnostic::Engine::*;
import Diagnostic::Registry::*;
import Diagnostic::PrettyConsumer::*;
import Location::SourceManager::*;
import Token::TokenCacheManager::*;
import Config::Invocation::*;
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::GlobalDisambigTable::*;
import AST::CodeCompleteConsumer::*;
import AST::Node::Program::*;
import Parser::ASTParse::*;

/// \class ParsedSource
/// \brief owns the full frontend state produced by parsing one in-memory
///        snippet: infrastructure, token stream, ASTContext, and the TU.
///
/// \details construction runs the pipeline eagerly:
///            load_virtual -> lex -> index -> parse -> drain diagnostics.
///          check ok() before touching tu(). The object must outlive every
///          node pointer taken from it   the ASTContext arena lives here.
///
/// \note heap-create via parse_source() and release with std::destroy.
///       Copying is not meaningful; treat as move-only/owner.
class ParsedSource {
    // --- Owned infrastructure (construction order; destroyed in reverse) ----
    priv var _pool:   *ThreadPool           = &null;
    priv var _vfm:    *VirtualFileManager   = &null;
    priv var _diag:   *DiagEngine           = &null;
    priv var _pretty: *PrettyDiagConsumer   = &null;
    priv var _sm:     *SourceManager        = &null;
    priv var _tcm:    *TokenCacheManager    = &null;
    priv var _gs:     *GlobalDisambigTable   = &null;

    // --- Snippet state -------------------------------------------------------
    priv var _code: libcxx::string;      ///< owns the bytes; SM holds a raw view.
    priv var _inv:  CompilerInvocation;  ///< default invocation (no CLI).
    priv var _fid:  u32 = u32(-1);
    priv var _tu:   *TranslationUnit = &null;
    priv var _ok:   bool = false;

    /// \brief runs the string -> TU pipeline.
    ///
    /// \param code        the Kairo source text to parse.
    /// \param vname       logical file name used in diagnostics/ranges.
    /// \param echo_diags  when true, diagnostics render to the terminal via
    ///                    PrettyDiagConsumer; when false they are counted only.
    fn ParsedSource(self, code: string, vname: string, echo_diags: bool) {
        // infra: mirrors CompilerInstance construction order, minimally.
        self._pool = std::create::<ThreadPool>(1);
        self._vfm  = std::create::<VirtualFileManager>();
        self._diag = std::create::<DiagEngine>();
        self._sm   = std::create::<SourceManager>(self._pool, self._vfm, self._diag);
        self._tcm  = std::create::<TokenCacheManager>(self._sm, self._pool, self._diag);
        self._gs   = std::create::<GlobalDisambigTable>();

        if echo_diags {
            self._pretty = std::create::<PrettyDiagConsumer>(self._sm);
            self._diag->add_consumer(self._pretty);
        }

        // the snippet must outlive the virtual file: SM keeps a raw pointer.
        var nstr = std::string_to_nstring(code);
        self._code = libcxx::string(nstr);

        self._fid = self._sm->load_virtual(
            Path(vname, false),
            reinterpret_cast::<std::ConstPtr::<u8>>(self._code.data()),
            self._code.size()
        );
        if self._fid == u32(-1) { return; }

        if !self._tcm->lex_file(self._fid) { return; }

        // index phase: builds the DisambigTable + owns the ASTContext.
        // resolver is null   snippets cannot resolve imports (no preprocess).
        self._gs->index_file(
            self._fid, self._sm, self._tcm, self._diag, &null, &(self._inv)
        );

        var ctx = self._gs->get_context(self._fid);
        if ctx == &null { return; }

        var parser = ASTParse(ctx, &null, self._gs);
        self._tu = parser.parse();
        ctx->tu = reinterpret_cast::<*void>(self._tu);

        // publish buffered parse diagnostics to the engine (prints + counts).
        ctx->diag_sink.drain_into(self._diag);

        self._ok = (self._tu != &null) && (!self._diag->has_fatal());
    }

    fn op delete (self) {
        // _gs owns the ASTContext (and with it the TU arena)   destroy first.
        if self._gs     != &null { std::destroy(self._gs);     }
        if self._tcm    != &null { std::destroy(self._tcm);    }
        if self._sm     != &null { std::destroy(self._sm);     }
        if self._pretty != &null {
            self._diag->remove_consumer(self._pretty);
            std::destroy(self._pretty);
        }
        if self._diag   != &null { std::destroy(self._diag);   }
        if self._vfm    != &null { std::destroy(self._vfm);    }
        if self._pool   != &null { std::destroy(self._pool);   }
    }

    // --- Results -------------------------------------------------------------

    /// \brief true if the pipeline produced a TU and no fatal diagnostic fired.
    ///        parse errors do NOT clear ok()   the TU is error-resilient;
    ///        check error_count() if you need a clean parse.
    fn ok(self) -> bool { return self._ok; }

    /// \brief true if the snippet parsed with zero errors and no fatals.
    fn clean(self) -> bool {
        return self._ok && (self._diag->error_count() == 0);
    }

    fn tu(self)  -> *TranslationUnit { return self._tu; }
    fn fid(self) -> u32              { return self._fid; }

    fn ctx(self) -> *ASTContext {
        if self._gs == &null { return &null; }
        return self._gs->get_context(self._fid);
    }

    fn program(self) -> *Program {
        if self._tu == &null { return &null; }
        return self._tu->program;
    }

    // --- Diagnostics ----------------------------------------------------------

    fn diag(self)        -> *DiagEngine { return self._diag; }
    fn error_count(self) -> u32 { return self._diag->error_count(); }
    fn warn_count(self)  -> u32 { return self._diag->warn_count();  }
}

/// \brief parses a string of Kairo source into a TranslationUnit.
///
/// \param code        the source text.
/// \param vname       logical file name for diagnostics (default "<snippet>").
/// \param echo_diags  render diagnostics to the terminal (default true).
///
/// \return heap-allocated ParsedSource; caller releases with std::destroy.
///         Never null   check ->ok() / ->clean() for outcome.
fn parse_source(
    code:       string,
    vname:      string = "<snippet>",
    echo_diags: bool   = true
) -> *ParsedSource {
    return std::create::<ParsedSource>(code, vname, echo_diags);
}
