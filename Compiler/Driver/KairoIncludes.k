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
ffi "c++" import "Native/ClangSemaAgree.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Context::ASTContext::ASTContext
import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import Codegen::Backend::CodegenAction::{
    agree_fill_from,
    agree_finding,
    agree_log_counts,
}
import Codegen::Backend::IncludeEmitter::{
    IncludeEmitter,
    IncludedDecls,
}
import Codegen::Backend::SemaAgreeReport::AgreeFinding
import Codegen::Sink::TokenSink::{
    AgreeSite,
    TokenSink,
}
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
    /// The records of `agree`, on the Kairo side and in its order, and for
    /// each the context of the file whose stream wrote it.
    priv var _agree_sites: cxx::std::vector<AgreeSite>
    priv var _agree_ctx:   cxx::std::vector<unsafe *ASTContext>
    /// What the Sema agreement walk found in the host TUs run so far, with
    /// the context each is reported through. The driver reports and
    /// clears them after each run (take_agree_found): a disagreement in a
    /// stream a C++ file included is Kairo's finding, said at the Kairo
    /// call, never a diagnostic of the C++ file.
    pub var agree_found: cxx::std::vector<AgreeFinding>
    pub var agree_ctx:   cxx::std::vector<unsafe *ASTContext>

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

    /// Turns the Sema agreement pass on for the Kairo streams of every
    /// host TU: \p repair and \p count_unrecorded as
    /// KairoInject::agree_start.
    pub fn agree_start(self, repair: bool, count_unrecorded: bool) {
        if self.agree == &null {
            self.agree = kairo::std::create<kairo::SemaAgreeTable>()
        }

        self.agree->repair           = repair
        self.agree->count_unrecorded = count_unrecorded
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
        em.agree = self.agree != &null
        var before = self._sinks.size()
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

        // The stream's records join the host TU's table before clang lexes
        // the stream: the walk runs as its declarations are parsed.
        if self.agree != &null && self._sinks.size() > before {
            var unsafe *s = self._sinks.back()
            self.agree->block_base = self._locmap->block_base()
            self.agree->block_n    = self._locmap->mapped_count() as u32
            agree_fill_from(self.agree, s)
            for var k: usize = 0; k < s->agree_sites.size(); ++k {
                self._agree_sites.push_back(s->agree_sites[k])
                self._agree_ctx.push_back(ctx)
            }
        }

        return true
    }

    override fn end_tu(self) {
        // While this host TU's map and sinks live.
        if self.agree != &null {
            if self._bound != &null && self._locmap != &null && self._agree_sites.size() > 0 {
                agree_log_counts(
                    self.agree,
                    "the Kairo files a C++ translation unit includes",
                )

                var n = self.agree->finding_count()
                for var i: usize = 0; i < n; ++i {
                    var site = self.agree->finding_call(i) as usize
                    if site >= self._agree_sites.size() {
                        continue
                    }

                    self.agree_found.push_back(
                        agree_finding(
                            self.agree,
                            i,
                            self._agree_sites[site],
                            self._agree_ctx[site],
                            self._locmap,
                        ),
                    )

                    self.agree_ctx.push_back(self._agree_ctx[site])
                }
            }

            self.agree->reset()
            self._agree_sites.clear()
            self._agree_ctx.clear()
        }

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
        if self.agree != &null {
            kairo::std::destroy(self.agree)
            self.agree = &null
        }

        if self._locmap != &null {
            kairo::std::destroy(self._locmap)
            self._locmap = &null
        }
    }
}
