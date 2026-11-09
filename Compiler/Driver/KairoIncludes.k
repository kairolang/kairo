/// --- The Kairo Project ----------------------- Driver/KairoIncludes.k --- ///
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
///   (every Kairo fid registered once, on the first .k it includes), the
///   TokenSinks the streams were built in, and what the streams so far put
///   in it (IncludedDecls), all released at end_tu.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/Frontend/CompilerInstance.h"
ffi "c++" import "clang/Lex/Token.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import Codegen::Backend::IncludeEmitter::{
    IncludeEmitter,
    IncludedDecls,
}
import Codegen::Sink::TokenSink::TokenSink
import Interop::Clang::ClangLocMap::ClangLocMap
import Interop::Clang::KairoInclude::KairoIncludeSource
import Location::SourceManager::{
    FileID,
    SourceManager,
}
import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable
import Support::FileIO::Path::Path

pub class DriverIncludeSource derives KairoIncludeSource {
    priv var _ksm:   *SourceManager
    priv var _scope: *GlobalDisambigTable
    priv var _psym:  unsafe *PreprocessorSymbolTable
    /// False when the Kairo TUs stop before sema (a build with no C++
    /// input, CompilerInstance::kairo_feeds_includes): the emitter reads
    /// lowered trees.
    priv var _lowered: bool = false

    priv var _locmap: unsafe *ClangLocMap                 = &null ///< owned; this host TU's
    priv var _bound:  unsafe *clang::CompilerInstance     = &null
    priv var _sinks:  cxx::std::vector<unsafe *TokenSink>         ///< owned; this host TU's
    priv var _seen:   IncludedDecls                               ///< this host TU's

    fn DriverIncludeSource(self,
                           ksm:     *SourceManager,
                           scope:   *GlobalDisambigTable,
                           psym:    unsafe *PreprocessorSymbolTable,
                           lowered: bool) {
        self._ksm     = ksm
        self._scope   = scope
        self._psym    = psym
        self._lowered = lowered
    }

    override fn tokens_for(self,
                           ci:         unsafe *clang::CompilerInstance,
                           cfid:       clang::FileID,
                           const path: string,
                           out:        unsafe *cxx::std::vector<clang::Token>) -> bool {
        self.include_lines.clear()
        var kfid = self._ksm->find_fid(Path(path))
        if kfid == (u32::MAX as FileID) {
            self.error = "it is not part of this build; pass it on the command line"
            return false
        }

        var unsafe *ctx = self._scope->get_context(kfid)
        if ctx == &null {
            self.error = "it is not part of this build; pass it on the command line"
            return false
        }

        var unsafe *tu = ctx->tu
        if tu == &null || tu->is_foreign {
            self.error = "it is not a Kairo module of this build"
            return false
        }

        if !self._lowered || self._psym == &null {
            self.error = "this build stops before analysing it, which an included Kairo file needs"
            return false
        }

        // Once per host TU: rebind mints a FileID per Kairo file, and the
        // set is final by now (every Kairo TU ran before any C/C++ input).
        if self._bound != ci {
            if self._locmap == &null {
                self._locmap = kairo::std::create<ClangLocMap>(self._ksm)
            }

            if !self._locmap->rebind(ci) {
                self.error = "its source could not be mapped into this translation unit"
                return false
            }

            self._bound = ci
        }

        var ksize = (self._ksm->get_file_size(kfid) as u32)
        var em    = IncludeEmitter()
        if !em.emit(
            ci,
            self._locmap,
            ctx,
            kfid,
            ksize,
            self._psym,
            self._scope->instances(),
            out,
            unsafe &self._sinks,
            unsafe &self.include_lines,
            unsafe &self._seen,
        ) {
            self.error = em.error
            return false
        }

        return true
    }

    override fn end_tu(self) {
        for var i: usize = 0; i < self._sinks.size(); ++i {
            kairo::std::destroy(self._sinks[i])
        }

        self._sinks.clear()
        self._seen.clear()
        self._bound = &null
    }

    // Not transferable: clang's include hook points at it and it owns the sinks and location map; a copy would free them twice.
    @copy fn DriverIncludeSource(self, const other: Self) = delete

    fn op finally (self) {
        self.end_tu()
        if self._locmap != &null {
            kairo::std::destroy(self._locmap)
            self._locmap = &null
        }
    }
}
