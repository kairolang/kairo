/// --- The Kairo Project ----------------------------------- Extras/Formatter/Driver/kfmt.k --- ///
///
///   kfmt driver: AST -> Doc IR -> text.
///
///   The fmt_* family lives on `Formatter` rather than at file scope because
///   rendering a node needs the ASTContext to resolve tokens and interned
///   strings (`tok`/`istr`), exactly as AstDumper does. Free functions cannot
///   take `self`.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::ASTSupport::*;
import AST::Context::TranslationUnit::*;
import AST::Mixin::TypeQual::*;
import AST::Mixin::Annotation::*;
import AST::Visitor::RecursiveASTVisitor::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Types::*;
import AST::Node::Patterns::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::ExprKind::*;
import AST::Kind::TypeKind::*;
import AST::Kind::StmtKind::*;
import AST::Kind::PatternKind::*;
import Location::SourceManager::*;
import Token::TokenKind::*;

import Renderer::*;

class Formatter {
    pub var ctx: obs::<ASTContext>;

    fn Formatter(self, ctx: *ASTContext) {
        self.ctx = ctx;
    }

    /// Target column. Kairo has no file- or class-scope `const` binding, so
    /// the formatter's tunables are static accessors.
    static fn line_width() -> i32 { return 100; }

    /// Rule 3 cap: at most this many consecutive blank lines survive.
    static fn max_blank_lines() -> usize { return 4; }

    /// ----------------------------------------------------------------------
    /// Name resolution (mirrors AstDumper: always source spelling, never a
    /// token-kind word)
    /// ----------------------------------------------------------------------

    fn tok(self, t: Token) -> string {
        return self.ctx->get_spelling(t);
    }

    fn istr(self, s: u32) -> string {
        if self.ctx->hoisted != &null { return self.ctx->hoisted->str(s); }
        return "<ffi>";
    }

    /// ----------------------------------------------------------------------
    /// Format Classifiers
    /// ----------------------------------------------------------------------

    fn fmt_quals(self, ty: *Type) -> Doc {
        type TQ = TypeQual::<Type>;

        // compared as Flags, not a narrowed integer: Flags derives u16 and
        // IsPanic is 1 << 8, which a u8 cast silently drops.
        var f     = ty->flags;
        var none  = TQ::Flags::None;
        var parts = vec::<Doc>();

        if (f & TQ::Flags::IsConst)    != none { parts.push_back(Doc::text("const "));    }
        if (f & TQ::Flags::IsVolatile) != none { parts.push_back(Doc::text("volatile ")); }
        if (f & TQ::Flags::IsRestrict) != none { parts.push_back(Doc::text("restrict ")); }
        if (f & TQ::Flags::IsAtomic)   != none { parts.push_back(Doc::text("atomic "));   }
        if (f & TQ::Flags::IsUnsafe)   != none { parts.push_back(Doc::text("unsafe "));   }
        if (f & TQ::Flags::IsEval)     != none { parts.push_back(Doc::text("eval "));     }
        if (f & TQ::Flags::IsAsync)    != none { parts.push_back(Doc::text("async "));    }
        if (f & TQ::Flags::IsYield)    != none { parts.push_back(Doc::text("yield "));    }
        if (f & TQ::Flags::IsPanic)    != none { parts.push_back(Doc::text("panic "));    }

        return Doc::concat(parts);
    }

    fn fmt_type(self, ty: *Type) -> Doc {
        if ty == &null    { return Doc::text("<error>"); }
        if ty->is_error() { return Doc::text("<error>"); }

        if isa::<ChainType>(ty)             { return self._ft_chain(cast::<ChainType>(ty)); }
        if isa::<GenericParamType>(ty)      { return self._ft_generic_param(cast::<GenericParamType>(ty)); }
        if isa::<SubstGenericParamType>(ty) { return self.fmt_type(cast::<SubstGenericParamType>(ty)->replacement); }
        if isa::<TypeOfType>(ty) {
            return Doc::concat3(self.fmt_quals(ty), Doc::text("typeof"), Doc::text("(...)"));
        }
        if isa::<VariadicPackType>(ty) {
            return Doc::concat2(Doc::text("..."), self.fmt_type(cast::<VariadicPackType>(ty)->param));
        }
        if isa::<PackExpansionType>(ty) {
            return Doc::concat2(self.fmt_type(cast::<PackExpansionType>(ty)->pattern), Doc::text("..."));
        }
        if isa::<PointerType>(ty) {
            return Doc::concat3(self.fmt_quals(ty), Doc::text("*"), self.fmt_type(cast::<PointerType>(ty)->pointee));
        }
        if isa::<NullableType>(ty) {
            return Doc::concat3(self.fmt_quals(ty), self.fmt_type(cast::<NullableType>(ty)->inner), Doc::text("?"));
        }
        if isa::<TupleType>(ty)      { return self._ft_tuple(cast::<TupleType>(ty)); }
        if isa::<FixedArrayType>(ty) { return self._ft_fixed_array(cast::<FixedArrayType>(ty)); }
        if isa::<VectorType>(ty) {
            return Doc::concat4(
                self.fmt_quals(ty),
                Doc::text("["),
                self.fmt_type(cast::<VectorType>(ty)->element),
                Doc::text("]")
            );
        }
        if isa::<MapType>(ty) { return self._ft_map(cast::<MapType>(ty)); }
        if isa::<SetType>(ty) {
            return Doc::concat4(
                self.fmt_quals(ty),
                Doc::text("{"),
                self.fmt_type(cast::<SetType>(ty)->element),
                Doc::text("}")
            );
        }
        if isa::<SelfType>(ty) { return Doc::concat2(self.fmt_quals(ty), Doc::text("Self")); }
        if isa::<FunctionPointerType>(ty) { return self._ft_fn_ptr(cast::<FunctionPointerType>(ty)); }
        if isa::<InferredType>(ty)  { return Doc::text("_"); }
        if isa::<CXXLValueRefType>(ty) {
            return Doc::concat3(
                self.fmt_quals(ty),
                self.fmt_type(cast::<CXXLValueRefType>(ty)->referee),
                Doc::text("&")
            );
        }
        if isa::<CXXRValueRefType>(ty) {
            return Doc::concat3(
                self.fmt_quals(ty),
                self.fmt_type(cast::<CXXRValueRefType>(ty)->referee),
                Doc::text("&&")
            );
        }
        if isa::<OpaqueFFIType>(ty) { return Doc::text(self.istr(cast::<OpaqueFFIType>(ty)->name)); }
        if isa::<TypeExpr>(ty) {
            return Doc::concat2(self.fmt_quals(ty), self.fmt_expr(cast::<TypeExpr>(ty)->expr));
        }

        return Doc::text("<error>");
    }

    /// `<A, Key: B>`. Empty argument lists render as nothing, not `<>`.
    fn fmt_generic_args(self, args: FrozenList::<ChainType::GenericArg>) -> Doc {
        if args.is_empty() { return Doc::nothing(); }

        var items = vec::<Doc>();
        items.push_back(Doc::text("<"));

        for var i: usize = 0; i < args.size(); ++i {
            if i > 0 {
                items.push_back(Doc::text(","));
                items.push_back(Doc::line());
            }

            var a = args.get(i);
            if a->name != &null {
                items.push_back(Doc::text(self.tok(a->name->name)));
                items.push_back(Doc::text(": "));
            }
            items.push_back(self.fmt_type(a->ty));
        }

        items.push_back(Doc::text(">"));
        return Doc::group(Doc::concat(items));
    }

    fn _ft_chain(self, ty: *ChainType) -> Doc {
        var parts = vec::<Doc>();
        parts.push_back(self.fmt_quals(ty));

        if ty->segments.is_empty() { return Doc::text("<error>"); }

        for var i: usize = 0; i < ty->segments.size(); ++i {
            var seg = ty->segments.get(i);
            if seg->sep == ChainType::SegmentSeparator::ColonColon {
                parts.push_back(Doc::text("::"));
            }
            if seg->name == &null { parts.push_back(Doc::text("<error>")); continue; }
            parts.push_back(Doc::text(self.tok(seg->name->name)));
            parts.push_back(self.fmt_generic_args(seg->generic_args));
        }

        return Doc::concat(parts);
    }

    fn _ft_generic_param(self, ty: *GenericParamType) -> Doc {
        var parts = vec::<Doc>();
        parts.push_back(self.fmt_quals(ty));
        if ty->is_pack { parts.push_back(Doc::text("...")); }
        if ty->param_name == &null { return Doc::text("<error>"); }
        parts.push_back(Doc::text(self.tok(ty->param_name->name)));
        return Doc::concat(parts);
    }

    fn _ft_tuple(self, ty: *TupleType) -> Doc {
        var items = vec::<Doc>();
        for var i: usize = 0; i < ty->elements.size(); ++i {
            if i > 0 { items.push_back(Doc::text(",")); items.push_back(Doc::line()); }
            items.push_back(self.fmt_type(ty->elements[i]));
        }

        return Doc::concat4(
            self.fmt_quals(ty),
            Doc::text("("),
            Doc::group(Doc::concat(items)),
            Doc::text(")")
        );
    }

    /// `[T; N]`, or `[T; ]` when the extent was left off (C-style `int buf[]`).
    fn _ft_fixed_array(self, ty: *FixedArrayType) -> Doc {
        var items = vec::<Doc>();
        items.push_back(self.fmt_quals(ty));
        items.push_back(Doc::text("["));
        items.push_back(self.fmt_type(ty->element));
        items.push_back(Doc::text("; "));
        if !ty->is_incomplete { items.push_back(self.fmt_expr(ty->size_expr)); }
        items.push_back(Doc::text("]"));
        return Doc::concat(items);
    }

    /// `{K: V}`.
    fn _ft_map(self, ty: *MapType) -> Doc {
        var items = vec::<Doc>();
        items.push_back(self.fmt_quals(ty));
        items.push_back(Doc::text("{"));
        items.push_back(self.fmt_type(ty->key));
        items.push_back(Doc::text(": "));
        items.push_back(self.fmt_type(ty->value));
        items.push_back(Doc::text("}"));
        return Doc::concat(items);
    }

    /// `fn(A, B) -> R`. An unprototyped C import has no parameter list to
    /// print, so it renders as `fn(...) -> R`.
    fn _ft_fn_ptr(self, ty: *FunctionPointerType) -> Doc {
        var items = vec::<Doc>();
        items.push_back(self.fmt_quals(ty));
        items.push_back(Doc::text("fn("));

        if ty->is_unprototyped {
            items.push_back(Doc::text("..."));
        } else {
            var params = vec::<Doc>();
            for var i: usize = 0; i < ty->params.size(); ++i {
                if i > 0 { params.push_back(Doc::text(",")); params.push_back(Doc::line()); }
                params.push_back(self.fmt_type(ty->params[i]));
            }
            items.push_back(Doc::group(Doc::concat(params)));
        }

        items.push_back(Doc::text(")"));
        items.push_back(Doc::text(" -> "));
        items.push_back(self.fmt_type(ty->return_type));
        return Doc::concat(items);
    }

    /// ----------------------------------------------------------------------
    /// NOT YET IMPLEMENTED
    ///
    /// The Doc IR, the renderer, and the type layer are complete. The decl /
    /// stmt / expr layers are not written yet   they are the bulk of the
    /// formatter and each needs its own per-node style decisions.
    ///
    /// They return a visible marker rather than source text, which is why
    /// format_one_file() refuses to write files back: emitting these markers
    /// into a .k file would destroy it.
    /// ----------------------------------------------------------------------

    fn fmt_expr(self, e: *Expr) -> Doc {
        if e == &null { return Doc::text("<error>"); }
        return Doc::text("<unimplemented-expr>");
    }

    fn fmt_decl(self, d: *Decl) -> Doc {
        if d == &null { return Doc::text("<error>"); }
        return Doc::text("<unimplemented-decl>");
    }

    fn fmt_stmt(self, s: *Stmt) -> Doc {
        if s == &null { return Doc::text("<error>"); }
        return Doc::text("<unimplemented-stmt>");
    }

    /// ----------------------------------------------------------------------
    /// Top level
    /// ----------------------------------------------------------------------

    /// Rule 3: how many blank lines separated the previous item's last line
    /// from this item's first, capped at MAX_BLANK_LINES.
    fn _blank_lines_before(self, prev_end_line: usize, next_start_line: usize) -> usize {
        if next_start_line <= (prev_end_line + 1) { return 0; }

        var gap = (next_start_line - prev_end_line) - 1;
        if gap > Formatter::max_blank_lines() { return Formatter::max_blank_lines(); }
        return gap;
    }

    /// SourceLocation stores only an encoded file+offset, so the line number
    /// has to come back through the SourceManager.
    fn _line_of(self, loc: SourceLocation) -> usize {
        if self.ctx == &null      { return 0; }
        if self.ctx->sm == &null  { return 0; }
        return self.ctx->sm->get_line_col(loc).line;
    }

    fn fmt_program(self, prog: *Program) -> Doc {
        if prog == &null { return Doc::nothing(); }

        var items = vec::<Doc>();
        var n     = prog->items.size();

        // usize is unsigned, so "no previous item" cannot be -1; the flag is
        // explicit instead.
        var have_prev: bool        = false;
        var prev_end_line: usize   = 0;

        for var i: usize = 0; i < n; ++i {
            var item = prog->items.get(i);
            if item == &null { continue; }

            var range = item->get_range();

            if have_prev {
                var gap = self._blank_lines_before(prev_end_line, self._line_of(range.start));
                for var b: usize = 0; b < gap; ++b { items.push_back(Doc::hardline()); }
            }

            switch item->get_kind() {
                case TopLevelKind::Decl { items.push_back(self.fmt_decl(item->as_decl())); }
                case TopLevelKind::Stmt { items.push_back(self.fmt_stmt(item->as_stmt())); }
                case TopLevelKind::Expr { items.push_back(self.fmt_expr(item->as_expr())); }
                default { items.push_back(Doc::text("<unknown-top-level>")); }
            }

            items.push_back(Doc::hardline());

            prev_end_line = self._line_of(range.end);
            have_prev     = true;
        }

        return Doc::concat(items);
    }
}

/// ----------------------------------------------------------------------
/// DRIVER
/// ----------------------------------------------------------------------

fn format_one_file(path: libcxx::filesystem::path) -> bool {
    // Wiring this up needs a frontend entry point that turns a file into a
    // TranslationUnit. Compiler/Parser/ParseSource.k is the intended one but
    // is itself still a stub (literal `...` placeholders, undeclared members),
    // so there is nothing to call yet.
    //
    // Until that lands AND fmt_decl/fmt_stmt/fmt_expr are real, formatting a
    // file would replace its contents with `<unimplemented-*>` markers.
    var name: string = path.generic_wstring();
    std::print(f"kfmt: not implemented yet, refusing to rewrite {name}");
    return false;
}

fn main(argc: i32, argv: *(*kairo::std::Legacy::char)) -> i32 {
    if argc != 2 {
        std::print("Usage: kfmt <input_folder>/<input_file>");
        return 1;
    }

    var target_path = argv[1];
    var path = libcxx::filesystem::path(target_path);

    if !libcxx::filesystem::exists(path) {
        std::print(f"Error: path does not exist: {target_path}");
        return 1;
    }

    var files_formatted: usize = 0;

    if libcxx::filesystem::is_directory(path) {
        for entry in libcxx::filesystem::recursive_directory_iterator(path) {
            // std::filesystem::path has no operator== against a Kairo string;
            // generic_wstring() is the conversion the rest of the tree uses.
            var ext: string = entry.path().extension().generic_wstring();
            if entry.is_regular_file() && (ext == ".k") {
                if !format_one_file(entry.path()) {
                    var name: string = entry.path().generic_wstring();
                    std::print(f"Error: failed to format {name}");
                    return 1;
                }
                files_formatted += 1;
            }
        }
    } else {
        var ext: string = path.extension().generic_wstring();
        if ext != ".k" {
            std::print(f"Error: not a .k file: {target_path}");
            return 1;
        }
        if !format_one_file(path) {
            std::print(f"Error: failed to format {target_path}");
            return 1;
        }
        files_formatted += 1;
    }

    std::print(f"Formatted {files_formatted} file(s)");
    return 0;
}
