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

    /// --emit-headers-layout (kals' clangd bridge; implies line_directives):
    /// each declaration on the PHYSICAL line it has in the .k file, since
    /// clangd reports physical lines (TextSink::finish_layout). What the
    /// emitter invents goes to \ref prelude, written beside the header as
    /// `<header>.prelude` and included from its second line by absolute
    /// path (clangd may present the header under the .k file's name, so a
    /// relative include would resolve against the wrong directory).
    pub var layout:  bool   = false
    pub var prelude: string = ""

    /// Layout only: what became of the module's doc comments
    /// (TextSink::docs_placed): on their own lines, on a forward declaration
    /// in the prelude, or dropped for want of room.
    pub var docs_placed:  usize = 0
    pub var docs_prelude: usize = 0
    pub var docs_dropped: usize = 0

    /// Layout only: out-of-line function bodies left out, their declarations
    /// holding their lines, and kept because C++ may need them
    /// (TextSink::bodies_dropped).
    pub var  bodies_dropped: usize  = 0
    pub var  bodies_needed:  usize  = 0
    priv var _prelude_path:  string = ""

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
            var pcg = CodegenContext(
                self._ctx,
                &null,
                self._psym,
                self._instances,
            )

            var pplan = EmitPlan(unsafe &pcg, PlanMode::Preamble)
            pplan.run()
            if pplan.is_empty() {
                return ""
            }
        }

        var ts = TextSink(self._ctx->sm, self._ctx->tcm)
        ts.line_mode = self.line_directives
        ts.self_path = self.header_name
        ts.layout    = self.layout && self.line_directives
        if ts.layout && (self._ctx->sm != &null) {
            ts.home_path = self._ctx->sm->get_filename(tu->fid)
        }

        var cg = CodegenContext(
            self._ctx,
            unsafe &ts,
            self._psym,
            self._instances,
        )

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
        cg.advance_phase(CodegenPhase::Emitted)
        if ts.line_mode {
            ts.brk() // the last line is still buffered
        }

        if ts.layout {
            self.prelude = ts.finish_layout(
                "#include \"" + self._prelude_path + "\"",
            )

            self.docs_placed    = ts.docs_placed
            self.docs_prelude   = ts.docs_prelude
            self.docs_dropped   = ts.docs_dropped
            self.bodies_dropped = ts.bodies_dropped
            self.bodies_needed  = ts.bodies_needed
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
        var cg = CodegenContext(self._ctx, &null, self._psym, self._instances)
        var sp = CXXSpell(unsafe &cg)
        return dir + "/" + sp.header_path(tu)
    }

    /// Render and write. False if nothing to write or the write failed.
    pub fn write(self, const dir: string) -> bool {
        var p = self.path_under(dir)
        if self.line_directives && self.header_name.empty() {
            self.header_name = p
        }

        if self.layout && self.line_directives {
            Path::make_parent_dirs(p)
            self._prelude_path = Path::join_str(
                Path::real_path_of(Path::parent_of(p)),
                Path::filename_of(p) + ".prelude",
            )
        }

        var text = self.render()
        if text.size() == 0 {
            return false
        }

        if self.layout && self.line_directives {
            var oldp: string = ""
            if (!LinkFS::read(self._prelude_path, &oldp)) || (oldp != self.prelude) {
                Path::write_file(self._prelude_path, self.prelude)
            }
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
