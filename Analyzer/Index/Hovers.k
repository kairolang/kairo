/// --- The Kairo Project ----------------------- Analyzer/Index/Hovers.k --- ///
///
///   Hover text: signatures, doc comments, members, layout.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///


ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::ImportOverlay::{
    ImportOverlay,
    OverlayVisibility,
}
import AST::Context::SymbolTable::{
    DeclName,
    OverloadCell,
    SymbolTable,
}
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts::{
    decl_extension_of,
    decl_generic_params,
    decl_is_ffi,
    decl_is_imported,
    decl_name_tok,
    decl_requires_clause,
}
import AST::Mixin::Annotation::{
    AnnotationKind,
    VisibilityKind,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Types
import AST::ParamMode::param_mode_prefix
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Engine::DiagEngine
import DocumentStore::LineMap
import Index::Bases::*
import Index::CompletionItems::*
import Index::Indexer::*
import Index::Inlays::*
import Index::Legend::*
import Index::Macros::*
import Index::Refs::*
import Index::Snapshot::*
import Index::Tokens::*
import Index::Writer::*
import Json::JsonWriter
import Lexer::Immediate::ImmediateTable
import Lexer::Lexer::Lexer
import Location::SourceLocation::SourceLocation
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Resolution::ModulePath::path_separator
import Sema::Lower::EnumLayoutLowering::EnumLayoutQuery
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::SemaDump::sema_dump_decl_name
import Sema::Type::TypeUtil::TypeUtil
import Token::Token::Token
import Token::TokenKind::{
    TokenKind,
    is_keyword,
}
import Token::TokenText::TokenText

/// How far a type's head is read from its start for the hover (to its `{`):
/// a head longer than this falls back to the keyword and the name.
const TYPE_HEAD_SCAN_BYTES: usize = 800

extend IndexWalker {
    /// A type as a diagnostic spells it. Through TypeUtil, not TypePrinter:
    /// an inferred type is a canonical node with no source form, and only
    /// the Sema printer knows how to spell those.
    fn type_str_(self, t: unsafe *Type, ctx: unsafe *ASTContext) -> string {
        if (t == &null) || (ctx == &null) {
            return ""
        }

        // `Self` as written: the printer resolves it to whatever it stands
        // for, and an interface's `fn op +(self, Self) -> Self` must not read
        // as if it named the interface.
        if isa<Types::SelfType>(t) {
            return "Self"
        }

        var s = self.tu_.str(t)
        if s.starts_with("<") {
            // "<unknown>", "<error>": nothing a reader can use.
            return ""
        }

        return s
    }

    /// The source text of \p r, whitespace runs folded to one space: an
    /// attribute as its author wrote it (`@align(8)`, `@deprecated("...")`).
    /// Empty for a range that is not one stretch of one file.
    fn source_text_(self, r: SourceRange) -> string {
        var out: string = ""
        if (!r.start.is_valid()) || (!r.end.is_valid()) || (r.end.raw() <= r.start.raw()) {
            return out
        }

        var res = self.sm->resolve(r.start)
        var fi  = self.file_(res.fid as u32)
        var so  = res.offset as usize
        var n   = (r.end.raw() - r.start.raw()) as usize
        if (n > 512) || ((so + n) > self.files[fi].text.size()) {
            return out
        }

        var space = false
        for var i: usize = so; i < so + n; ++i {
            var ch = self.files[fi].text[i]
            if (ch == (' ' as u8))
                || (ch == ('\t' as u8))
                || (ch == ('\n' as u8))
                || (ch == ('\r' as u8)) {
                space = true
                continue
            }

            if space && (!out.empty()) {
                out += " "
            }

            space = false
            out += self.files[fi].text.subslice(i, 1)
        }

        return out
    }

    /// What the source wrote in front of \p d's keyword, each followed by a
    /// space: its attributes in order, as spelled (the parser keeps every one,
    /// including those it also turns into a field, like `@copy` into
    /// FunctionDecl::transfer), then its visibility keyword. Nothing for a
    /// declaration imported from C++ or made by the compiler: neither wrote
    /// a Kairo head, and the visibility an importer stamps is not one.
    fn head_(self, d: unsafe *Decl) -> string {
        var s: string = ""
        if (d == &null) || d->is_implicit || decl_is_ffi(d) {
            return s
        }

        if d->has_attribute() {
            for var i: usize = 0; i < d->annotations.size(); ++i {
                var unsafe *e = d->annotations.get(i)
                if e->kind != AnnotationKind::Attribute {
                    continue
                }

                var t = self.source_text_(e->range)
                if t.empty() || (t[0] != ('@' as u8)) {
                    continue // not an `@` the text shows: a range a macro made
                }

                s += t
                s += " "
            }
        }

        if d->visibility == VisibilityKind::Public {
            s += "pub "
        } else if d->visibility == VisibilityKind::Private {
            s += "priv "
        } else if d->visibility == VisibilityKind::Protected {
            s += "prot "
        }

        return s
    }

    /// Index of \p needle in \p hay at a word start (the front, or after a
    /// space), or usize::MAX.
    fn word_in_(const self, const hay: string, const needle: string) -> usize {
        if needle.empty() || (hay.size() < needle.size()) {
            return usize::MAX
        }

        for var i: usize = 0; (i + needle.size()) <= hay.size(); ++i {
            if (i > 0) && (hay[i - 1] != (' ' as u8)) {
                continue
            }

            if hay.subslice(i, needle.size()) == needle {
                return i
            }
        }

        return usize::MAX
    }

    /// The head of type \p d as the source wrote it, from its keyword \p kw
    /// ("class ", with the space) to its body: generic parameters, name,
    /// `derives` and `impl` lists, on one line. A `where` / `requires`
    /// clause is cut: it is the rule, not what the type is. "" when the
    /// text is not there to read (a declaration a macro made, one without
    /// a body), and the caller writes the keyword and the name.
    fn type_head_text_(self, d: unsafe *Decl, const kw: string) -> string {
        var none: string = ""
        if (d == &null) || (!d->range.start.is_valid()) {
            return none
        }

        var res           = self.sm->resolve(d->range.start)
        var fi            = self.file_(res.fid as u32)
        var i             = res.offset as usize
        var n             = self.files[fi].text.size()
        var raw:   string = ""
        var space         = false
        var closed        = false
        var steps: usize  = 0
        while (i < n) && (steps < TYPE_HEAD_SCAN_BYTES) {
            var ch = self.files[fi].text[i]
            if ch == ('{' as u8) {
                closed = true
                break
            }

            if (ch == (' ' as u8))
                || (ch == ('\t' as u8))
                || (ch == ('\n' as u8))
                || (ch == ('\r' as u8)) {
                space = true
            } else {
                if space && (!raw.empty()) {
                    raw += " "
                }

                space = false
                raw += self.files[fi].text.subslice(i, 1)
            }

            i += 1
            steps += 1
        }

        if !closed {
            return none
        }

        var at = self.word_in_(raw, kw)
        if at == usize::MAX {
            return none
        }

        var head = raw.subslice(at, raw.size() - at)
        var cut  = self.word_in_(head, "where ")
        var req  = self.word_in_(head, "requires ")
        if req < cut {
            cut = req
        }

        if cut != usize::MAX {
            head = head.subslice(0, cut)
        }

        while (!head.empty()) && (head[head.size() - 1] == (' ' as u8)) {
            head = head.subslice(0, head.size() - 1)
        }

        return head
    }

    /// A binding's storage keyword as the source spells it.
    fn storage_kw_(self,
                   sc:            Declarations::StorageClass,
                   is_thread:     bool,
                   const_binding: bool,
                   is_mut:        bool) -> string {
        if is_thread {
            return if (const_binding) => ("thread const ") else => "thread "
        }

        if sc == Declarations::StorageClass::Static {
            return if (const_binding) => ("static const ") else => "static "
        }

        if sc == Declarations::StorageClass::Const {
            return "const "
        }

        if sc == Declarations::StorageClass::Eval {
            return "eval "
        }

        return if (is_mut) => ("mutable var ") else => "var "
    }

    /// The declaration as one line of Kairo: what a hover shows in its code
    /// block and a completion item shows as its detail.
    ///
    /// \p full is the hover's form: the head (head_), a function's
    /// modifiers and its `= default` / `= delete` / `= virtual`, a
    /// parameter's attributes. Without it, the declaration alone, which is
    /// what a completion detail, an outline row and the signature
    /// comparisons in Bases.k want. A function's modifiers are kept as bits
    /// (a leading `inline fn` and a trailing `fn f() inline` are one), so
    /// they are written in one place: `static`/`virtual`/`override`,
    /// `final`, `inline`, `eval`, `const` before `fn`; `unsafe`, `async`,
    /// `volatile` and the `panic` specifier after the parameters.
    fn signature_(self, d: unsafe *Decl, full: bool = false) -> string {
        if d == &null {
            return ""
        }

        var head: string = ""
        if full {
            head = self.head_(d)
        }

        var unsafe *ctx = NameLookup::ctx_of(d)
        if ctx == &null {
            ctx = self.ast_()
        }

        var name = sema_dump_decl_name(ctx, d)

        if isa<Declarations::FunctionDecl>(d) {
            var unsafe *f        = cast<Declarations::FunctionDecl>(d)
            var        s: string = head
            if full && (!d->is_implicit) && (!decl_is_ffi(d)) {
                if f->abi == Declarations::AbiKind::Static {
                    s += "static "
                } else if f->abi == Declarations::AbiKind::Virtual {
                    s += "virtual "
                } else if f->abi == Declarations::AbiKind::Override {
                    s += "override "
                }

                if ((f->modifiers as u16) & (Declarations::FnModifier::IsFinal as u16)) != 0 {
                    s += "final "
                }

                // NameResolution marks a few library constructors constexpr
                // and inline together; only an `inline` with no constexpr
                // beside it is the author's.
                if f->is_inline() && (!f->is_constexpr()) {
                    s += "inline "
                }

                if f->is_eval() {
                    s += "eval "
                }

                if f->is_const_fn {
                    s += "const "
                }
            }

            s += "fn "
            s += name
            s += "("
            var ffi_fn = decl_is_ffi(d)
            for var i: usize = 0; i < f->params.size(); ++i {
                var unsafe *p = f->params[i]
                if i > 0 {
                    s += ", "
                }

                if full {
                    s += self.head_(unsafe (p as unsafe *Decl))
                }

                // Only a mode the source wrote: ClassLifecycle makes a
                // transfer constructor's `other` @inout itself.
                if p->mode_range.is_valid() {
                    s += param_mode_prefix(p->mode)
                }

                if p->is_const {
                    s += "const "
                }

                if p->is_self {
                    s += "self"
                    continue
                }

                // A requirement may leave a parameter unnamed (`fn op + (self,
                // Self)`): the type alone is its spelling.
                // An unnamed parameter has no name TOKEN either, and asking for
                // the spelling of an empty token is an ICE: test first.
                var pt = self.type_str_(p->type_, ctx)
                // A C++ reference parameter, as Kairo passes it: `T&` is
                // `@inout x: T`, `T&&` is `@move x: T`, `const T&` is
                // `const x: T`. A reference return reads `ffi::ref<T>` /
                // `ffi::mref<T>`, as a Kairo definition spells it.
                if ffi_fn && (!p->mode_range.is_valid()) {
                    var cref = pt.starts_with("const ")
                        && pt.ends_with("&")
                        && (!pt.ends_with("&&"))
                    if pt.ends_with("&&") {
                        s += "@move "
                        pt = pt.subslice(0, pt.size() - 2)
                    } else if cref {
                        if !p->is_const {
                            s += "const "
                        }

                        pt = pt.subslice(6, pt.size() - 7)
                    } else if pt.ends_with("&") {
                        s += "@inout "
                        pt = pt.subslice(0, pt.size() - 1)
                    }

                    while (!pt.empty()) && (pt[pt.size() - 1] == (' ' as u8)) {
                        pt = pt.subslice(0, pt.size() - 1)
                    }
                }

                if p->unname || (!p->name.range.start.is_valid()) {
                    s += pt
                    continue
                }

                var pn = ctx->get_spelling(p->name)
                if pn.empty() || pn.starts_with("$") {
                    s += pt
                    continue
                }

                s += pn
                if !pt.empty() {
                    s += ": "
                    s += pt
                }
            }

            s += ")"
            if full && (!d->is_implicit) && (!decl_is_ffi(d)) {
                if f->is_unsafe() {
                    s += " unsafe"
                }

                if f->is_async() {
                    s += " async"
                }

                if ((f->modifiers as u16) & (Declarations::FnModifier::IsVolatile as u16)) != 0 {
                    s += " volatile"
                }

                // As written, its set included; an inferred set is no
                // specifier (the parser alone sets the range).
                var pt = self.source_text_(f->panic_range)
                if !pt.empty() {
                    s += " "
                    s += pt
                }
            }

            var rt = self.type_str_(f->return_type, ctx)
            if (f->return_type != &null)
                && (!rt.empty())
                && (f->return_type->canonical != &null)
                && (isa<Types::CXXLValueRefType>(f->return_type->canonical)
                    || isa<Types::CXXRValueRefType>(f->return_type->canonical)) {
                rt = self.tu_.return_str(f->return_type->canonical)
            }

            if (!rt.empty()) && (rt != "void") {
                s += " -> "
                s += rt
            }

            if full {
                if f->body_kind == Declarations::FnBodyKind::Default {
                    s += " = default"
                } else if f->body_kind == Declarations::FnBodyKind::Delete {
                    s += " = delete"
                } else if f->body_kind == Declarations::FnBodyKind::Virtual {
                    s += " = virtual"
                }
            }

            if f->where_lead != &null {
                s += "  // where-dispatched"
            }

            return s
        }

        if isa<Declarations::VariableDecl>(d) {
            var unsafe *v = cast<Declarations::VariableDecl>(d)
            var s: string = head + self.storage_kw_(
                v->storage,
                v->is_thread,
                v->const_binding,
                false,
            )

            s += name
            var t = self.type_str_(v->type_, ctx)
            if !t.empty() {
                s += ": "
                s += t
            }

            return s
        }

        if isa<Declarations::ParamDecl>(d) {
            var unsafe *p        = cast<Declarations::ParamDecl>(d)
            var        s: string = "(parameter) " + head
            if p->is_self {
                return s + "self"
            }

            if p->mode_range.is_valid() {
                s += param_mode_prefix(p->mode)
            }

            s += name
            var t = self.type_str_(p->type_, ctx)
            if !t.empty() {
                s += ": "
                s += t
            }

            return s
        }

        if isa<Declarations::FieldDecl>(d) {
            var unsafe *f = cast<Declarations::FieldDecl>(d)
            var s: string = head + self.storage_kw_(
                f->storage,
                f->is_thread,
                f->const_binding,
                f->is_mutable,
            )

            s += name
            var t = self.type_str_(f->type_, ctx)
            if !t.empty() {
                s += ": "
                s += t
            }

            return s
        }

        if isa<Declarations::TypeAliasDecl>(d) {
            var s: string = head + "type "
            s += name
            var t = self.type_str_(
                cast<Declarations::TypeAliasDecl>(d)->aliased,
                ctx,
            )

            if !t.empty() {
                s += " = "
                s += t
            }

            return s
        }

        // A variant names the enum it belongs to and carries its value or
        // payload: hovering `Green` alone does not say which enum or which
        // number it is.
        if isa<Declarations::EnumVariantDecl>(d) {
            var s: string = "(variant) " + head
            if (d->semantic_dc != &null)
                && (d->semantic_dc->dc_owner != &null)
                && isa<Declarations::EnumDecl>(d->semantic_dc->dc_owner) {
                s += sema_dump_decl_name(ctx, d->semantic_dc->dc_owner)
                s += path_separator()
            }

            return s + self.variant_line_(
                cast<Declarations::EnumVariantDecl>(d),
                ctx,
            )
        }

        // An enum's underlying type is part of what it is (its size, what
        // `as` gives); a plain enum without `derives` is u32 by the rule in
        // enums-plain.
        if isa<Declarations::EnumDecl>(d) {
            var unsafe *e = cast<Declarations::EnumDecl>(d)
            // The hover's form: the head as written (generic parameters,
            // `derives`), and the default underlying type where none is.
            if full && (!d->is_implicit) && (!decl_is_ffi(d)) {
                var th = self.type_head_text_(d, "enum ")
                if !th.empty() {
                    if (e->underlying == &null)
                        && (!e->is_adt)
                        && (self.word_in_(th, "derives ") == usize::MAX) {
                        th += " derives u32 /* default */"
                    }

                    return head + th
                }
            }

            var s: string = head + "enum "
            s += name
            if e->underlying != &null {
                var t = self.type_str_(e->underlying, ctx)
                if !t.empty() {
                    s += " derives "
                    s += t
                }
            } else if !e->is_adt {
                s += " derives u32 /* default */"
            }

            return s
        }

        var kw: string = ""
        if isa<Declarations::ClassDecl>(d) {
            kw = if (full && cast<Declarations::ClassDecl>(d)->is_final) => ("final class ")
                 else => "class "
        } else if isa<Declarations::StructDecl>(d) {
            kw = "struct "
        } else if isa<Declarations::UnionDecl>(d) {
            kw = "union "
        } else if isa<Declarations::InterfaceDecl>(d) {
            kw = "interface "
        } else if isa<Declarations::EnumDecl>(d) {
            kw = "enum "
        } else if isa<Declarations::EnumVariantDecl>(d) {
            kw = "(variant) "
        } else if isa<Declarations::ModuleDecl>(d) {
            kw = "module "
        } else if isa<Declarations::GenericParamDecl>(d) {
            kw = "(type parameter) "
        } else if isa<Declarations::MacroDecl>(d) {
            kw = "macro "
        }

        // A type's head as written: `class <T> Box derives Base impl Add`.
        if full
            && (!d->is_implicit)
            && (!decl_is_ffi(d))
            && (isa<Declarations::ClassDecl>(d)
                || isa<Declarations::StructDecl>(d)
                || isa<Declarations::UnionDecl>(d)
                || isa<Declarations::InterfaceDecl>(d)) {
            var bare = if (isa<Declarations::ClassDecl>(d)) => ("class ") else => kw
            var th = self.type_head_text_(d, bare)
            if !th.empty() {
                if kw.starts_with("final ") {
                    return head + "final " + th
                }

                return head + th
            }
        }

        return head + kw + name
    }

    /// The `///` lines directly above \p d, markers stripped, joined by
    /// newlines.
    ///
    /// Read from the TEXT, not from the tree: under --preserve-comments the
    /// tree carried doc comments for some library declarations and for none
    /// of a project file's, and the flag also turns a test file's
    /// `// RUN:` lines into annotations. The lines above a name are
    /// exactly what a reader calls its documentation.
    fn doc_(self, d: unsafe *Decl) -> string {
        var out: string = ""
        var name        = decl_name_tok(d)
        var at          = name.range.start
        if !at.is_valid() {
            at = d->range.start
        }

        if !at.is_valid() {
            return out
        }

        var res  = self.sm->resolve(at)
        var fi   = self.file_(res.fid as u32)
        var line = self.files[fi].lines.line_of(res.offset as usize)

        // Walk up over the block: `///` lines, and attribute lines between
        // the comment and the declaration (`@inline`, a visibility keyword
        // on its own line).
        var first           = line
        var lines: [string]
        while first > 0 {
            var ls = self.files[fi].lines.starts[first - 1]
            var le = self.files[fi].lines.line_end(
                self.files[fi].text,
                first - 1,
            )

            var p = ls
            while (p < le)
                && ((self.files[fi].text[p] == (' ' as u8))
                    || (self.files[fi].text[p] == ('\t' as u8))) {
                p += 1
            }

            if ((p + 2) < le)
                && (self.files[fi].text[p] == ('/' as u8))
                && (self.files[fi].text[p + 1] == ('/' as u8))
                && (self.files[fi].text[p + 2] == ('/' as u8)) {
                p += 3
                if (p < le) && (self.files[fi].text[p] == (' ' as u8)) {
                    p += 1
                }

                lines.push_back(self.files[fi].text.subslice(p, le - p))
                first -= 1
                continue
            }

            if ((p + 2) == le)
                && (self.files[fi].text[p] == ('/' as u8))
                && (self.files[fi].text[p + 1] == ('/' as u8)) {
                break // a bare `//` ends a doc block
            }

            if (p < le) && (self.files[fi].text[p] == ('@' as u8)) && lines.empty() {
                first -= 1 // an attribute line above the declaration
                continue
            }

            break
        }

        // A license banner is not documentation: the block that opens a file
        // with a `/// ---` rule belongs to the file.
        if (!lines.empty()) && lines[lines.size() - 1].starts_with("--- ") {
            return out
        }

        var n = lines.size()
        for var i: usize = 0; i < n; ++i {
            if i > 0 {
                out += "\n"
            }

            out += lines[n - 1 - i]
        }

        return out
    }

    /// For a type: its body as a reader wants it on hover. An interface lists
    /// every requirement, the inherited ones too (the inlay hint that shows
    /// them is one line and editors cut it short). A class, struct or union
    /// lists its fields and methods, then the methods `extend` blocks add.
    /// Empty for anything that is not a type.
    fn members_(self, d: unsafe *Decl) -> string {
        var lines: [string]
        if isa<Declarations::InterfaceDecl>(d) {
            var unsafe *it = cast<Declarations::InterfaceDecl>(d)
            // The plain signatures, for the duplicate test: an inherited
            // requirement is the declaration alone (inherited_methods_).
            var own: [string]
            for var i: usize = 0; i < it->methods.size(); ++i {
                lines.push_back(
                    "    " + self.signature_(
                        unsafe (it->methods[i] as unsafe *Decl),
                        true,
                    ),
                )

                own.push_back(
                    self.signature_(unsafe (it->methods[i] as unsafe *Decl)),
                )
            }

            var inherited: [string]
            self.inherited_methods_(d, 0, &inherited)
            for var i: usize = 0; i < inherited.size(); ++i {
                var line = "    " + inherited[i]
                var dup  = false
                for var k: usize = 0; k < own.size(); ++k {
                    if own[k] == inherited[i] {
                        dup = true
                    }
                }

                if !dup {
                    lines.push_back(line + "  // inherited")
                }
            }
        } else if isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d) {
            var fields: [unsafe *Decl]
            var meths:  [unsafe *Decl]
            if isa<Declarations::ClassDecl>(d) {
                var unsafe *c = cast<Declarations::ClassDecl>(d)
                for var i: usize = 0; i < c->fields.size(); ++i {
                    fields.push_back(unsafe (c->fields[i] as unsafe *Decl))
                }
            } else if isa<Declarations::StructDecl>(d) {
                var unsafe *c = cast<Declarations::StructDecl>(d)
                for var i: usize = 0; i < c->fields.size(); ++i {
                    fields.push_back(unsafe (c->fields[i] as unsafe *Decl))
                }
            } else {
                var unsafe *c = cast<Declarations::UnionDecl>(d)
                for var i: usize = 0; i < c->fields.size(); ++i {
                    fields.push_back(unsafe (c->fields[i] as unsafe *Decl))
                }
            }

            self.methods_of_(d, &meths)
            if isa<Declarations::UnionDecl>(d) {
                var unsafe *c = cast<Declarations::UnionDecl>(d)
                for var i: usize = 0; i < c->methods.size(); ++i {
                    meths.push_back(unsafe (c->methods[i] as unsafe *Decl))
                }
            }

            for var i: usize = 0; (i < fields.size()) && (lines.size() < 40); ++i {
                if !fields[i]->is_implicit {
                    lines.push_back("    " + self.signature_(fields[i], true))
                }
            }

            for var i: usize = 0; (i < meths.size()) && (lines.size() < 40); ++i {
                if !meths[i]->is_implicit {
                    lines.push_back("    " + self.signature_(meths[i], true))
                }
            }

            // What `extend` blocks add, from every file of the build: an
            // extension is found by the type it targets, not by an import.
            var fids = self.sc->g->all_fids()
            for var fi: usize = 0; (fi < fids.size()) && (lines.size() < 60); ++fi {
                var unsafe *octx = self.sc->g->get_context(fids[fi])
                if (octx == &null) || (octx->tu == &null) {
                    continue
                }

                var *decls = &octx->tu->dc_decls
                for var k: usize = 0; k < decls->size(); ++k {
                    var unsafe *e = *decls->get(k)
                    if (e == &null) || (!isa<Declarations::ExtensionDecl>(e)) {
                        continue
                    }

                    var unsafe *ext = cast<Declarations::ExtensionDecl>(e)
                    if self.decl_of_type_(ext->target) != d {
                        continue
                    }

                    for var m: usize = 0; (m < ext->methods.size()) && (lines.size() < 60); ++m {
                        lines.push_back(
                            "    " + self.signature_(
                                unsafe (ext->methods[m] as unsafe *Decl),
                                true,
                            ) + "  // extend",
                        )
                    }
                }
            }
        } else if isa<Declarations::EnumDecl>(d) {
            var unsafe *e   = cast<Declarations::EnumDecl>(d)
            var unsafe *ctx = NameLookup::ctx_of(d)
            if ctx == &null {
                ctx = self.ast_()
            }

            for var i: usize = 0; (i < e->variants.size()) && (lines.size() < 60); ++i {
                lines.push_back(
                    "    " + self.head_(
                        unsafe (e->variants[i] as unsafe *Decl),
                    ) + self.variant_line_(e->variants[i], ctx),
                )
            }
        } else {
            return ""
        }

        if lines.empty() {
            return " { }"
        }

        var out: string = " {"
        for var i: usize = 0; i < lines.size(); ++i {
            out += "\n"
            out += lines[i]
        }

        out += "\n}"
        return out
    }

    /// One variant as it reads in its enum: `Name { a: T, b: U }` for a
    /// payload, `Name = 3` for a plain variant whose value Sema computed
    /// (implicit values too: the reader wants the number, not the rule).
    fn variant_line_(self,
                     v:   unsafe *Declarations::EnumVariantDecl,
                     ctx: unsafe *ASTContext) -> string {
        var s: string = sema_dump_decl_name(ctx, unsafe (v as unsafe *Decl))
        if v->payload.size() > 0 {
            s += " { "
            for var k: usize = 0; k < v->payload.size(); ++k {
                var unsafe *f = v->payload[k]
                if k > 0 {
                    s += ", "
                }

                s += sema_dump_decl_name(ctx, unsafe (f as unsafe *Decl))
                var t = self.type_str_(f->type_, ctx)
                if !t.empty() {
                    s += ": "
                    s += t
                }
            }

            s += " }"
            return s
        }

        if v->value.ok {
            s += " = "
            if v->value.neg {
                s += "-"
            }

            var mag = v->value.mag
            s += f"{mag}"
        }

        return s
    }

    /// "size N bytes, align M" for a type declaration, or "" when the
    /// compiler does not know it.
    ///
    /// The number is the compiler's own: EnumLayoutQuery::size_of, which
    /// declaration-scope `eval if` folds `sizeof` with and codegen pins an
    /// ADT instance's predicted size to with a static_assert, asked in its
    /// foreign mode (EnumLayoutQuery::foreign), which also reads what clang
    /// decided for an imported record or enum and what mono filled in for a
    /// Kairo generic instance. It answers a plain enum, an ADT (its tag,
    /// prefix or niche layout), a struct or class with no base, no generic
    /// parameter and no virtual method, with `@packed` / `@align` applied,
    /// and any C++ record clang laid out. A Kairo class with a base (Kairo
    /// or C++, virtual or not) or a virtual method, a `@packed` record of
    /// record fields, and a union as a field are clang's own answer too:
    /// the C++ the compiler emits for them has a layout only clang decides
    /// (tail padding reuse, the vtable pointer, what a packed record packs),
    /// so the query has clang lay out a twin of the emitted class
    /// (EnumLayoutQuery::_twin_record). Not a generic pattern: its
    /// instances are laid out per argument (a use that names one gets that
    /// one's, hover_typed_). Anything else is nothing rather than a guess. An
    /// ADT has its layout only once EnumLayoutLowering has built it, so
    /// this runs from fill_layouts_, after the TU's lowerings and mono.
    fn layout_(self, d: unsafe *Decl) -> string {
        if (self.sc == &null) || (d == &null) {
            return ""
        }

        // A Kairo-written FFI mirror: its C++ is the header's, not this
        // declaration.
        if decl_is_ffi(d) && (!decl_is_imported(d)) {
            return ""
        }

        // A generic pattern is no type: each instance has its own layout,
        // and the query would answer the pattern as if it had one.
        if decl_generic_params(d).size() > 0 {
            return ""
        }

        if isa<Declarations::TypeAliasDecl>(d) {
            return self.layout_of_type_(
                cast<Declarations::TypeAliasDecl>(d)->aliased,
            )
        }

        if !(isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d)
            || isa<Declarations::EnumDecl>(d)) {
            return ""
        }

        // Nested in a generic record, it is that record's current
        // instantiation: per instance too.
        return self.layout_of_type_(self.sc->types->record(d, &null))
    }

    /// The same for a type: \p t's canonical, concrete form.
    fn layout_of_type_(self, t_in: unsafe *Type) -> string {
        if (t_in == &null) || (self.sc == &null) {
            return ""
        }

        var unsafe *t = t_in
        if t->canonical != &null {
            t = t->canonical
        }

        if t->is_dependent() || t->is_instantiation_dependent() {
            return ""
        }

        var        size:  u64 = 0
        var        align: u64 = 0
        var unsafe *c         = canon_unqual(t)
        if (c != &null)
            && isa<RecordType>(c)
            && isa<Declarations::UnionDecl>(cast<RecordType>(c)->decl)
            && (!decl_is_imported(cast<RecordType>(c)->decl)) {
            if !self.union_layout_(
                cast<Declarations::UnionDecl>(cast<RecordType>(c)->decl),
                &size,
                &align,
            ) {
                return ""
            }

            return f"size {size} bytes, align {align}" + self.target_note_()
        }

        var q = EnumLayoutQuery(self.sc)
        q.foreign = true
        if !q.size_of(t, unsafe &size, unsafe &align) {
            return ""
        }

        return f"size {size} bytes, align {align}" + self.target_note_()
    }

    /// The numbers are the entry's target's (builtin widths and clang's
    /// header sets both follow the invocation's TargetOptions): said when
    /// the entry named one with --target, which may not be the host.
    fn target_note_(self) -> string {
        var unsafe *ctx = self.ast_()
        if (ctx == &null) || (ctx->ci == &null) || ctx->ci->target.triple.empty() {
            return ""
        }

        return " on " + ctx->ci->target.triple
    }

    /// The hover of a use whose type is \p t, a type that is not \p d's own
    /// (an instance of generic \p d, or the target of alias \p d): \p d's
    /// hover with \p t's layout line, naming \p t. u32::MAX when \p t is
    /// \p d's own type or no concrete record, so the use keeps \p d's hover.
    fn hover_typed_(self, d: unsafe *Decl, t_in: unsafe *Type) -> u32 {
        if (d == &null) || (t_in == &null) || (t_in->canonical == &null) {
            return u32::MAX
        }

        var unsafe *c = canon_unqual(t_in->canonical)
        if (c == &null)
            || (!isa<RecordType>(c))
            || c->is_dependent()
            || c->is_instantiation_dependent() {
            return u32::MAX
        }

        var unsafe *rd = cast<RecordType>(c)->decl
        if (rd == &null) || (rd == d) {
            return u32::MAX
        }

        if !(isa<Declarations::TypeAliasDecl>(d) || (decl_generic_params(d).size() > 0)) {
            return u32::MAX
        }

        var key = ((c as usize) as u64) | 1
        var hit = self.hover_of_.get(key)
        if hit != null {
            return *hit
        }

        var base = self.hovers[self.hover_(d) as usize]
        // Past the code block's closing fence, where hover_ puts the line.
        var at = base.size()
        for var k: usize = 9; (k + 4) <= base.size(); ++k {
            if (base[k] == ('\n' as u8))
                && (base[k + 1] == ('`' as u8))
                && (base[k + 2] == ('`' as u8))
                && (base[k + 3] == ('`' as u8)) {
                at = k + 4
                break
            }
        }

        self.hovers.push_back(base)
        var        idx  = (self.hovers.size() - 1) as u32
        var unsafe *ctx = NameLookup::ctx_of(d)
        if ctx == &null {
            ctx = self.ast_()
        }

        self.layout_hover_.push_back(idx)
        self.layout_at_.push_back(at)
        self.layout_decl_.push_back(d)
        self.layout_type_.push_back(c)
        self.layout_name_.push_back(self.type_str_(c, ctx))
        self.hover_of_[key] = idx
        return idx
    }

    /// A union, which size_of does not answer: every member at offset 0, the
    /// widest member rounded up to the strictest alignment (C++'s rule for a
    /// union, the record Kairo's is written as). The one layout rule this
    /// file keeps, and only over members size_of answers; a generic union,
    /// or a layout attribute on the union or a member, is not answered.
    fn union_layout_(self, u: unsafe *Declarations::UnionDecl, size: *u64, align: *u64) -> bool {
        var unsafe *d = unsafe (u as unsafe *Decl)
        if (u->generic_params.size() > 0) || d->has_attribute() {
            return false
        }

        var q = EnumLayoutQuery(self.sc)
        q.foreign = true
        var big: u64 = 0
        var al:  u64 = 1
        var any      = false
        for var i: usize = 0; i < u->fields.size(); ++i {
            var unsafe *f = u->fields[i]
            if (f == &null) || f->is_static() {
                continue
            }

            if unsafe (f as unsafe *Decl)->has_attribute() {
                return false
            }

            var fs: u64 = 0
            var fa: u64 = 0
            if !q.size_of(f->type_, unsafe &fs, unsafe &fa) {
                return false
            }

            if fs > big {
                big = fs
            }

            if fa > al {
                al = fa
            }

            any = true
        }

        if !any {
            return false
        }

        (*size)  = ((big + al - 1) / al) * al
        (*align) = al
        return true
    }

    /// The layout lines the walk left out (hover_), now that the TU is
    /// lowered. The worker calls it from SemaObserver::on_lowered.
    pub fn fill_layouts_(self) {
        for var i: usize = 0; i < self.layout_hover_.size(); ++i {
            var lay: string = ""
            if self.layout_type_[i] != &null {
                lay = self.layout_of_type_(self.layout_type_[i])
                if (!lay.empty()) && (!self.layout_name_[i].empty()) {
                    lay += " (`" + self.layout_name_[i] + "`)"
                }
            } else {
                lay = self.layout_(self.layout_decl_[i])
            }

            if lay.empty() {
                continue
            }

            var idx = self.layout_hover_[i] as usize
            var at  = self.layout_at_[i]
            var h   = self.hovers[idx]
            self.hovers[idx] = h.subslice(0, at) + "\n\n" + lay + h.subslice(
                at,
                h.size() - at,
            )
        }
    }

    /// Index of \p d's hover text in `hovers`, building it on first use.
    fn hover_(self, d: unsafe *Decl) -> u32 {
        var key = (d as usize) as u64
        var hit = self.hover_of_.get(key)
        if hit != null {
            return *hit
        }

        var sig        = self.signature_(d, true)
        var md: string = "```kairo\n"
        md += sig
        md += self.members_(d)
        md += "\n```"

        // The layout line goes here once the TU is lowered (fill_layouts_).
        var lay_at = md.size()

        // Where it lives, when that is a type or a module: `Foo::bar` reads
        // differently from a free `bar`.
        if (d->semantic_dc != &null) && (d->semantic_dc->dc_owner != &null) {
            var unsafe *owner = d->semantic_dc->dc_owner
            var        on     = sema_dump_decl_name(self.ast_(), owner)
            if (!on.empty()) && (!isa<Declarations::FunctionDecl>(owner)) {
                md += "\n\nin `"
                md += on
                md += "`"
            }
        }

        var doc = self.doc_(d)
        if !doc.empty() {
            md += "\n\n---\n\n"
            md += doc
        }

        self.hovers.push_back(md)
        var idx = (self.hovers.size() - 1) as u32
        if isa<Declarations::ClassDecl>(d)
            || isa<Declarations::StructDecl>(d)
            || isa<Declarations::UnionDecl>(d)
            || isa<Declarations::EnumDecl>(d)
            || isa<Declarations::TypeAliasDecl>(d) {
            self.layout_hover_.push_back(idx)
            self.layout_at_.push_back(lay_at)
            self.layout_decl_.push_back(d)
            self.layout_type_.push_back(&null)
            self.layout_name_.push_back("")
        }

        self.hover_of_[key] = idx
        return idx
    }

    // --- emitting --------------------------------------------------------
}
