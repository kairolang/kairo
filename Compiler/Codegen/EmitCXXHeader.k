/// --- The Kairo Project ---------------------- Codegen/EmitCXXHeader.k --- ///
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Codegen::CodegenContext::*;
import Codegen::EmitPlan::*;
import Codegen::TextSink::*;
import Codegen::Emit::InterfaceEmitter::*;
import Codegen::Emit::CXXSpell::*;
import AST::Context::ASTContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::InstantiationRegistry::*;
import Preprocessor::PreprocessorSymbolTable::*;
import Support::FileIO::Path::*;

class EmitCXXHeader {
    priv var _ctx:       obs::<ASTContext>;
    priv var _psym:      obs::<PreprocessorSymbolTable>;
    priv var _instances: obs::<InstantiationRegistry>;

    fn EmitCXXHeader(self, ctx: *ASTContext, psym: *PreprocessorSymbolTable,
                     instances: *InstantiationRegistry) {
        self._ctx       = ctx;
        self._psym      = psym;
        self._instances = instances;
    }

    /// The header text, or "" for a TU that has none (the entry TU).
    fn render(self) -> string {
        var tu = reinterpret_cast::<*TranslationUnit>(self._ctx->tu);
        if (tu == &null) || CXXSpell::is_entry_tu(tu) { return ""; }
        var ts = TextSink(self._ctx->sm, self._ctx->tcm);
        var cg = CodegenContext(self._ctx, &ts, self._psym, self._instances);
        var plan = EmitPlan(&cg, PlanMode::Header);
        plan.run();
        cg.advance_phase(CodegenPhase::Planned);
        InterfaceEmitter(&cg, &plan).run();
        return ts.out;
    }

    /// The path under \p dir this TU's header lands at.
    fn path_under(self, dir: string) -> string {
        var tu = reinterpret_cast::<*TranslationUnit>(self._ctx->tu);
        var cg = CodegenContext(self._ctx, &null, self._psym, self._instances);
        var sp = CXXSpell(&cg);
        return dir + "/" + sp.header_path(tu);
    }

    /// Render and write. False if nothing to write or the write failed.
    fn write(self, dir: string) -> bool {
        var text = self.render();
        if text.size() == 0 { return false; }
        var p  = std::string_to_nstring(self.path_under(dir));
        var nt = std::string_to_nstring(text);
        var ok = false;
        inline "c++" {
            libcxx::filesystem::path fp(p.raw_string());
            libcxx::error_code ec;
            libcxx::filesystem::create_directories(fp.parent_path(), ec);
            libcxx::ofstream ofs(fp);
            if (ofs) { ofs << nt.raw_string(); ok = bool(ofs); }
        }
        return ok;
    }
}