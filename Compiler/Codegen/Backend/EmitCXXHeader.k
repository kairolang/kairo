/// --- The Kairo Project -------------- Codegen/Backend/EmitCXXHeader.k --- ///
///
///   \brief The module's C++ interop header: the same InterfaceEmitter over
///          a header-mode plan, into a TextSink, written to
///          `<dir>/<module path>.hh`.
///
///   Not a clang action: no PP, no PCH. It needs sema's resolved links and
///   nothing else, so it can run right after sema, per TU, and the entry
///   TU (no module path, nothing importable) never gets one.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import API::FS::LinkFS
import AST::Context::ASTContext::ASTContext
import AST::Context::InstantiationRegistry::InstantiationRegistry
import AST::Context::TranslationUnit::TranslationUnit
import Codegen::CodegenContext::{
    CodegenContext,
    CodegenPhase,
}
import Codegen::Emit::CXXSpell::CXXSpell
import Codegen::Emit::EmitIR::EmitIR
import Codegen::Emit::InterfaceEmitter::InterfaceEmitter
import Codegen::EmitPlan::{
    EmitPlan,
    PlanMode,
}
import Codegen::Sink::TextSink::TextSink
import Interop::Clang::HeaderSet::HeaderSet
import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable
import Support::FileIO::Path::Path

pub class EmitCXXHeader {
    priv var _ctx:       unsafe *ASTContext
    priv var _psym:      unsafe *PreprocessorSymbolTable
    priv var _instances: unsafe *InstantiationRegistry

    /// kals' clangd bridge (--emit-headers-line-directives): `#line` before
    /// every emitted line naming the Kairo declaration it comes from, so a
    /// jump from C++ lands in the .k file; text with no Kairo counterpart
    /// sits under `#line` naming \ref header_name. Off for every other
    /// caller: a user-requested header is plain C++, and kcc injects tokens
    /// that already carry Kairo locations.
    pub var line_directives: bool   = false
    pub var header_name:     string = ""

    pub fn EmitCXXHeader(self,
                         ctx:       unsafe *ASTContext,
                         psym:      unsafe *PreprocessorSymbolTable,
                         instances: unsafe *InstantiationRegistry) {
        self._ctx       = ctx
        self._psym      = psym
        self._instances = instances
    }

    /// The header text, or "" for a TU that has none (a pathless one, which
    /// nothing can import or include by module path: CXXSpell::is_entry_tu).
    pub fn render(self) -> string {
        var unsafe *tu = self._ctx->tu
        if tu == &null || CXXSpell::is_entry_tu(tu) {
            return ""
        }

        // An empty TU declares nothing, and header includes follow Complete
        // dependencies on declarations, so nothing could include its header.
        // Emptiness is the PREAMBLE plan's fact, the same one the driver
        // skips codegen on, so the two cannot disagree about a TU.
        {
            var pcg   = CodegenContext(self._ctx, &null, self._psym, self._instances)
            var pplan = EmitPlan(unsafe &pcg, PlanMode::Preamble)
            pplan.run()
            if pplan.is_empty() {
                return ""
            }
        }

        var ts   = TextSink(self._ctx->sm, self._ctx->tcm)
        ts.line_mode = self.line_directives
        ts.self_path = self.header_name
        var cg   = CodegenContext(self._ctx, unsafe &ts, self._psym, self._instances)
        var plan = EmitPlan(unsafe &cg, PlanMode::Header)
        plan.run()
        cg.advance_phase(CodegenPhase::Planned)
        var ir = EmitIR(unsafe &cg)
        var ie = InterfaceEmitter(unsafe &cg, unsafe &plan)
        ie.ir = unsafe &ir // the early items (EmitPlan::early), defined in tier 1.
        ie.set_ffi_lines(self._ffi_lines(tu))
        ie.run()
        // The module's inline and template bodies, after every class
        // definition: C++ consumers need them for the reason Kairo importers
        // do -- they are part of the interface. Out of line, so the class
        // definitions stay byte-identical to every TU's (Pipeline.md invariant 24).
        ir.emit_visible(unsafe &plan)
        if ts.line_mode {
            ts.brk() // the last line is still buffered
        }
        return ts.out
    }

    /// `#include "h"` per ffi header the module imports, as spelled, in
    /// source order; an `ffi "c"` one inside extern "C" as the module's own
    /// TU parsed it. Quoted, so a consumer finds them through the same -I
    /// roots the Kairo build used.
    priv fn _ffi_lines(self, tu: unsafe *TranslationUnit) -> cxx::std::vector<string> {
        var out = cxx::std::vector<string>()
        if tu->header_set == &null {
            return out
        }

        var unsafe *hs = unsafe (tu->header_set as unsafe *HeaderSet)
        for var i: usize = 0; i < hs->headers.size(); ++i {
            var c    = i < hs->c_linkage.size() && hs->c_linkage[i] != 0
            var line = "#include \""
            line += hs->headers[i]
            line += "\""
            if c {
                out.push_back("extern \"C\" {")
            }

            out.push_back(line)
            if c {
                out.push_back("}")
            }
        }

        return out
    }

    /// The path under \p dir this TU's header lands at.
    pub fn path_under(self, const dir: string) -> string {
        var unsafe *tu = self._ctx->tu
        var        cg  = CodegenContext(self._ctx, &null, self._psym, self._instances)
        var        sp  = CXXSpell(unsafe &cg)
        return dir + "/" + sp.header_path(tu)
    }

    /// Render and write. False if nothing to write or the write failed.
    pub fn write(self, const dir: string) -> bool {
        var p = self.path_under(dir)
        if self.line_directives && self.header_name.empty() {
            self.header_name = p
        }

        var text = self.render()
        if text.size() == 0 {
            return false
        }

        // The bridge's headers are watched by clangd: an unchanged one is
        // left alone, so an edit that does not touch the interface does not
        // make clangd re-parse every file that includes it.
        if self.line_directives {
            var old: string = ""
            if LinkFS::read(p, &old) && (old == text) {
                return true
            }
        }

        Path::make_parent_dirs(p)
        return Path::write_file(p, text)
    }
}
