/// --- The Kairo Project ---------------------- Driver/KairoIncludes.k --- ///
///
///   The driver's answer to `#include "foo.k"` in a C++ input
///   (Interop/Clang/KairoInclude.k): foo.k must be a Kairo file of THIS
///   build -- given on the command line or imported by one -- because its
///   interface is emitted from the analysed tree the build already holds,
///   and its object is the one the build already wrote. C/C++ inputs
///   compile after every Kairo TU (CompilerInstance::execute), so by the
///   time clang meets the include, foo.k is through sema and lowering.
///
///   Per host TU: one ClangLocMap bound to the host's CompilerInstance
///   (every Kairo fid registered once, on the first .k it includes), and
///   the TokenSinks the streams were built in, all released at end_tu.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/Frontend/CompilerInstance.h";
ffi "c++" import "clang/Lex/Token.h";

import Location::SourceLocation::*;
import Location::SourceManager::*;
import Support::FileIO::Path::*;
import AST::Context::ASTContext::*;
import AST::Context::GlobalDisambigTable::*;
import AST::Context::TranslationUnit::*;
import AST::Context::InstantiationRegistry::*;
import Preprocessor::PreprocessorSymbolTable::*;
import Interop::Clang::ClangLocMap::*;
import Interop::Clang::KairoInclude::*;
import Codegen::Sink::TokenSink::*;
import Codegen::Backend::IncludeEmitter::*;

class DriverIncludeSource derives KairoIncludeSource {
    priv var _ksm:       obs::<SourceManager>;
    priv var _scope:     obs::<GlobalDisambigTable>;
    priv var _psym:      obs::<PreprocessorSymbolTable>;
    /// False when the build stops before codegen (--syntax-only and the
    /// like): no Kairo TU was lowered, and the emitter reads lowered trees.
    priv var _lowered:   bool = false;

    priv var _locmap:    opt::<ClangLocMap> = &null;   ///< owned; this host TU's
    priv var _bound:     obs::<clang::CompilerInstance> = &null;
    priv var _sinks:     vec::<*TokenSink>;            ///< owned; this host TU's

    fn DriverIncludeSource(self, ksm: *SourceManager, scope: *GlobalDisambigTable,
                           psym: *PreprocessorSymbolTable, lowered: bool) {
        self._ksm     = ksm;
        self._scope   = scope;
        self._psym    = psym;
        self._lowered = lowered;
    }

    override fn tokens_for(self, ci: *clang::CompilerInstance, cfid: clang::FileID,
                           path: string, out: *libcxx::vector::<clang::Token>) -> bool {
        self.system_headers.clear();
        var kfid = self._ksm->find_fid(Path(path));
        if kfid == static_cast::<FileID>(u32(-1)) {
            self.error = "it is not part of this build; pass it on the command line";
            return false;
        }
        var ctx = self._scope->get_context(static_cast::<u32>(kfid));
        if ctx == &null {
            self.error = "it is not part of this build; pass it on the command line";
            return false;
        }
        var tu = reinterpret_cast::<*TranslationUnit>(ctx->tu);
        if (tu == &null) || tu->is_foreign {
            self.error = "it is not a Kairo module of this build";
            return false;
        }
        if (!self._lowered) || (self._psym == &null) {
            self.error = "this build stops before code generation, which an included Kairo file needs";
            return false;
        }

        // Once per host TU: rebind mints a FileID per Kairo file, and the
        // set is final by now (every Kairo TU ran before any C/C++ input).
        if self._bound != ci {
            if self._locmap == &null { self._locmap = std::create::<ClangLocMap>(self._ksm); }
            if !self._locmap->rebind(ci) {
                self.error = "its source could not be mapped into this translation unit";
                return false;
            }
            self._bound = ci;
        }

        var ksize = static_cast::<u32>(self._ksm->get_file_size(kfid));
        var em = IncludeEmitter();
        if !em.emit(ci, self._locmap, ctx, kfid, ksize, self._psym, self._scope->instances(), out,
                    &(self._sinks), &(self.system_headers)) {
            self.error = em.error;
            return false;
        }
        return true;
    }

    override fn end_tu(self) {
        for var i: usize = 0; i < self._sinks.size(); ++i { std::destroy(self._sinks[i]); }
        self._sinks.clear();
        self._bound = &null;
    }

    fn op delete (self) {
        self.end_tu();
        if self._locmap != &null { std::destroy(self._locmap); self._locmap = &null; }
    }
}
