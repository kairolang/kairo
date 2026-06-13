/// --- The Kairo Project ---------- Compiler/AST/Printer/ASTPrinter.k ----- ///
///
///   Translation-unit level AST dump. Walks Program's TopLevelItems and
///   routes each to the matching node printer. Output is one item per
///   line block (printers own their own indentation), with a header and
///   diagnostic-count footer.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::TranslationUnit::*;
import AST::ASTContext::*;
import ASTNode::Base::*;
import ASTNode::Program::*;
import AST::Printer::StmtPrinter::*;
import AST::Printer::ExprPrinter::*;

class ASTPrinter {
    /// \brief dumps a full translation unit to stdout.
    static fn print(tu: *TranslationUnit, style: PrintStyle = PrintStyle::Debug) {
        if tu == &null {
            std::print("<null TranslationUnit>");
            return;
        }

        var name = ((tu->ctx->sm->get_filename(tu->fid))
                    if (tu->ctx != &null) else (string("<unknown>")));

        std::print(f"TranslationUnit '{name}' (fid={tu->fid})");

        if tu->program == &null {
            std::print("  <no program>");
            return;
        }

        var p = tu->program;
        std::print(f"`-Program ({p->items.size()} top-level items)");

        for var i: usize = 0; i < p->items.size(); ++i {
            var item = p->items.get(i);
            if item == &null { continue; }

            switch item->get_kind() {
                case TopLevelKind::Decl {
                    std::print(DeclPrinter::print(item->as_decl(), style));
                } case TopLevelKind::Stmt {
                    std::print(StmtPrinter::print(item->as_stmt(), style));
                } case TopLevelKind::Expr {
                    std::print(ExprPrinter::print(item->as_expr(), style));
                } default {
                    std::print(f"  <unknown TopLevelItem kind at index {i}>");
                }
            }
        }

        std::print(f"-- {tu->error_count} error(s), {tu->warn_count} warning(s) --");
    }
}