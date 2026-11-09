/// --- The Kairo Project ----------------------- AST/Printer/Printers.k --- ///
///
///   The public printing entry points: TypePrinter, ExprPrinter, StmtPrinter,
///   DeclPrinter and PatternPrinter (one node, source form or tree dump), and
///   ASTPrinter (a whole translation unit, for --print-ast). Each is a thin
///   facade over AstDumper (ASTPrinter.k).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/KShims.hh" // std_out
ffi "c++" import "cstdio"

import AST::Context::ASTContext::ASTContext
import AST::Context::TranslationUnit::TranslationUnit
import AST::Node::Base::{
    Decl,
    Expr,
    Pattern,
    Stmt,
    Type,
}
import AST::Node::Program::TopLevelKind
import AST::Printer::ASTPrinter::AstDumper
import AST::Printer::PrintCore::{
    Color,
    PrintOptions,
}
import std::io

pub class TypePrinter {
    static fn print(ty: unsafe *Type, ctx: unsafe *ASTContext) -> string {
        return TypePrinter::print(ty, ctx, PrintOptions::diag())
    }

    pub static fn print(ty: unsafe *Type, ctx: unsafe *ASTContext, opts: PrintOptions) -> string {
        var d = AstDumper(ctx, opts)
        if opts.is_debug() {
            d.dump_type(ty, true)
        } else {
            d.src_type(ty)
        }

        return d.p.out
    }
}

pub class ExprPrinter {
    static fn print(e: unsafe *Expr, ctx: unsafe *ASTContext) -> string {
        return ExprPrinter::print(e, ctx, PrintOptions::diag())
    }

    pub static fn print(e: unsafe *Expr, ctx: unsafe *ASTContext, opts: PrintOptions) -> string {
        var d = AstDumper(ctx, opts)
        if opts.is_debug() {
            d.dump_expr(e, true)
        } else {
            d.src_expr(e)
        }

        return d.p.out
    }
}

pub class StmtPrinter {
    static fn print(stmt: unsafe *Stmt, ctx: unsafe *ASTContext) -> string {
        return StmtPrinter::print(stmt, ctx, PrintOptions::diag())
    }

    pub static fn print(stmt: unsafe *Stmt, ctx: unsafe *ASTContext, opts: PrintOptions) -> string {
        var d = AstDumper(ctx, opts)
        if opts.is_debug() {
            d.dump_stmt(stmt, true)
        } else {
            d.src_stmt(stmt)
        }

        return d.p.out
    }
}

pub class DeclPrinter {
    static fn print(decl: unsafe *Decl, ctx: unsafe *ASTContext) -> string {
        return DeclPrinter::print(decl, ctx, PrintOptions::diag())
    }

    pub static fn print(decl: unsafe *Decl, ctx: unsafe *ASTContext, opts: PrintOptions) -> string {
        var d = AstDumper(ctx, opts)
        if opts.is_debug() {
            d.dump_decl(decl, true)
        } else {
            d.src_decl(decl)
        }

        return d.p.out
    }
}

pub class PatternPrinter {
    static fn print(pat: unsafe *Pattern, ctx: unsafe *ASTContext) -> string {
        return PatternPrinter::print(pat, ctx, PrintOptions::diag())
    }

    static fn print(pat: unsafe *Pattern, ctx: unsafe *ASTContext, opts: PrintOptions) -> string {
        var d = AstDumper(ctx, opts)
        if opts.is_debug() {
            d.dump_pattern(pat, true)
        } else {
            d.src_pattern(pat)
        }

        return d.p.out
    }
}

/// Translation-unit dump for --print-ast. Walks Program's top-level items and
/// routes each through the RAV-overridden dump_* facades, under one shared
/// AstDumper so the tree spine is continuous across items.
pub class ASTPrinter {
    static fn print(tu: unsafe *TranslationUnit) {
        ASTPrinter::print(tu, PrintOptions::dump())
    }

    pub static fn print(tu: unsafe *TranslationUnit, opts: PrintOptions) {
        if tu == &null {
            io::println("<null TranslationUnit>")
            return
        }

        if tu->ctx == &null {
            io::println("<TranslationUnit with no ASTContext>")
            return
        }

        var d     = AstDumper(tu->ctx, opts)
        var debug = opts.is_debug()

        // Banner + footer are tree-dump affordances; sema never prints them.
        // Suppress in flat/canonical so output matches the src_* form sema embeds.
        if debug {
            var name = tu->ctx->sm->get_filename(tu->fid)
            d.p.paint(Color::NodeKind, "TranslationUnit")
            d.p.put(f" '{name}'")
            d.p.paint(Color::Dim, f"(fid={tu->fid})")
            d.p.newline()
        }

        if tu->program == &null {
            if debug {
                d.p.paint(Color::Dim, "<no program>")
                d.p.newline()
            }

            io::println(f"{d.p.out}")
            return
        }

        var unsafe *prog = tu->program
        var        n     = prog->items.size()
        for var i: usize = 0; i < n; ++i {
            var unsafe *item = prog->items.get(i)
            if item == &null {
                continue
            }

            var last = i == n - 1
            match item->get_kind() {
                case TopLevelKind::Decl {
                    if debug {
                        d.dump_decl(item->as_decl(), last)
                    } else {
                        d.src_decl(item->as_decl())
                        d.p.newline()
                    }
                } case TopLevelKind::Stmt {
                    if debug {
                        d.dump_stmt(item->as_stmt(), last)
                    } else {
                        d.src_stmt(item->as_stmt())
                        d.p.newline()
                    }
                } case TopLevelKind::Expr {
                    if debug {
                        d.dump_expr(item->as_expr(), last)
                    } else {
                        d.src_expr(item->as_expr())
                        d.p.newline()
                    }
                }
            }
        }

        if debug {
            d.p.paint(Color::Dim, f"-- {tu->error_count} error(s), {tu->warn_count} warning(s) --")
            d.p.newline()
        }

        io::println(f"{d.p.out}")
        cxx::std::fflush(kairo::std_out())
    }
}
