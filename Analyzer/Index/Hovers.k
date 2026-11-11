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


import Index::Snapshot::*
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Context::ASTContext::ASTContext
import AST::Context::ImportOverlay::{
    ImportOverlay,
    OverlayVisibility,
}
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::SymbolTable::{
    DeclName,
    OverloadCell,
    SymbolTable,
}
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts::{
    decl_extension_of,
    decl_is_ffi,
    decl_name_tok,
    decl_requires_clause,
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
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Engine::DiagEngine
import DocumentStore::LineMap
import Json::JsonWriter
import Lexer::Immediate::ImmediateTable
import Lexer::Lexer::Lexer
import Location::SourceLocation::SourceLocation
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::SemaDump::sema_dump_decl_name
import Sema::Type::TypeUtil::TypeUtil
import Token::Token::Token
import Token::TokenText::TokenText
import Token::TokenKind::{
    TokenKind,
    is_keyword,
}
import Index::Bases::*
import Index::CompletionItems::*
import Index::Indexer::*
import Index::Inlays::*
import Index::Legend::*
import Index::Macros::*
import Index::Refs::*
import Index::Tokens::*
import Index::Writer::*

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

    /// The declaration as one line of Kairo: what a hover shows in its code
    /// block and a completion item shows as its detail.
    fn signature_(self, d: unsafe *Decl) -> string {
        if d == &null {
            return ""
        }

        var unsafe *ctx = NameLookup::ctx_of(d)
        if ctx == &null {
            ctx = self.ast_()
        }

        var name = sema_dump_decl_name(ctx, d)

        if isa<Declarations::FunctionDecl>(d) {
            var unsafe *f = cast<Declarations::FunctionDecl>(d)
            var s: string = "fn "
            s += name
            s += "("
            for var i: usize = 0; i < f->params.size(); ++i {
                var unsafe *p = f->params[i]
                if i > 0 {
                    s += ", "
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
            var rt = self.type_str_(f->return_type, ctx)
            if (!rt.empty()) && (rt != "void") {
                s += " -> "
                s += rt
            }

            if f->where_lead != &null {
                s += "  // where-dispatched"
            }

            return s
        }

        if isa<Declarations::VariableDecl>(d) {
            var unsafe *v = cast<Declarations::VariableDecl>(d)
            var s: string = "var "
            if v->storage == Declarations::StorageClass::Const {
                s = "const "
            } else if v->storage == Declarations::StorageClass::Static {
                s = "static "
            } else if v->storage == Declarations::StorageClass::Eval {
                s = "eval "
            }

            s += name
            var t = self.type_str_(v->type_, ctx)
            if !t.empty() {
                s += ": "
                s += t
            }

            return s
        }

        if isa<Declarations::ParamDecl>(d) {
            var unsafe *p = cast<Declarations::ParamDecl>(d)
            var s: string = "(parameter) "
            if p->is_self {
                return s + "self"
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
            var s: string = "var "
            s += name
            var t = self.type_str_(f->type_, ctx)
            if !t.empty() {
                s += ": "
                s += t
            }

            return s
        }

        if isa<Declarations::TypeAliasDecl>(d) {
            var s: string = "type "
            s += name
            var t = self.type_str_(cast<Declarations::TypeAliasDecl>(d)->aliased, ctx)
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
            var s: string = "(variant) "
            if (d->semantic_dc != &null) && (d->semantic_dc->dc_owner != &null)
                && isa<Declarations::EnumDecl>(d->semantic_dc->dc_owner) {
                s += sema_dump_decl_name(ctx, d->semantic_dc->dc_owner)
                s += "::"
            }

            return s + self.variant_line_(cast<Declarations::EnumVariantDecl>(d), ctx)
        }

        // An enum's underlying type is part of what it is (its size, what
        // `as` gives); a plain enum without `derives` is u32 by the rule in
        // enums-plain.
        if isa<Declarations::EnumDecl>(d) {
            var unsafe *e = cast<Declarations::EnumDecl>(d)
            var s: string = "enum "
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
            kw = "class "
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

        return kw + name
    }

    /// The `///` lines directly above \p d, markers stripped, joined by
    /// newlines.
    ///
    /// Read from the TEXT, not from the tree: under --preserve-comments the
    /// tree carried doc comments for some library declarations and for none
    /// of a project file's (P799), and the flag also turns a test file's
    /// `// RUN:` lines into annotations. The lines above a name are
    /// exactly what a reader calls its documentation.
    fn doc_(self, d: unsafe *Decl) -> string {
        var out: string = ""
        var name = decl_name_tok(d)
        var at   = name.range.start
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
        var first = line
        var lines: [string]
        while first > 0 {
            var ls = self.files[fi].lines.starts[first - 1]
            var le = self.files[fi].lines.line_end(self.files[fi].text, first - 1)
            var p  = ls
            while (p < le) && ((self.files[fi].text[p] == 32) || (self.files[fi].text[p] == 9)) {
                p += 1
            }

            if ((p + 2) < le) && (self.files[fi].text[p] == 47) && (self.files[fi].text[p + 1] == 47)
                && (self.files[fi].text[p + 2] == 47) {
                p += 3
                if (p < le) && (self.files[fi].text[p] == 32) {
                    p += 1
                }

                lines.push_back(self.files[fi].text.subslice(p, le - p))
                first -= 1
                continue
            }

            if ((p + 2) == le) && (self.files[fi].text[p] == 47) && (self.files[fi].text[p + 1] == 47) {
                break // a bare `//` ends a doc block
            }

            if (p < le) && (self.files[fi].text[p] == 64) && lines.empty() {
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
            for var i: usize = 0; i < it->methods.size(); ++i {
                lines.push_back("    " + self.signature_(unsafe (it->methods[i] as unsafe *Decl)))
            }

            var inherited: [string]
            self.inherited_methods_(d, 0, &inherited)
            for var i: usize = 0; i < inherited.size(); ++i {
                var line = "    " + inherited[i]
                var dup = false
                for var k: usize = 0; k < lines.size(); ++k {
                    if lines[k] == line {
                        dup = true
                    }
                }

                if !dup {
                    lines.push_back(line + "  // inherited")
                }
            }
        } else if isa<Declarations::ClassDecl>(d) || isa<Declarations::StructDecl>(d) || isa<Declarations::UnionDecl>(d) {
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
                    lines.push_back("    " + self.signature_(fields[i]))
                }
            }

            for var i: usize = 0; (i < meths.size()) && (lines.size() < 40); ++i {
                if !meths[i]->is_implicit {
                    lines.push_back("    " + self.signature_(meths[i]))
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
                        lines.push_back("    " + self.signature_(unsafe (ext->methods[m] as unsafe *Decl)) + "  // extend")
                    }
                }
            }
        } else if isa<Declarations::EnumDecl>(d) {
            var unsafe *e = cast<Declarations::EnumDecl>(d)
            var unsafe *ctx = NameLookup::ctx_of(d)
            if ctx == &null {
                ctx = self.ast_()
            }

            for var i: usize = 0; (i < e->variants.size()) && (lines.size() < 60); ++i {
                lines.push_back("    " + self.variant_line_(e->variants[i], ctx))
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
    fn variant_line_(self, v: unsafe *Declarations::EnumVariantDecl, ctx: unsafe *ASTContext) -> string {
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

    /// Size and alignment in bytes of a field of type \p t, when they follow
    /// from arithmetic alone: a builtin, a pointer, a plain enum, or a record
    /// made of those. False for anything whose layout the C++ side decides.
    fn field_layout_(self, t_in: unsafe *Type, size: *u64, align: *u64, depth: u32) -> bool {
        if (t_in == &null) || (depth > 6) {
            return false
        }

        var unsafe *t = t_in
        if t->canonical != &null {
            t = t->canonical
        }

        t = canon_unqual(t)
        if t == &null {
            return false
        }

        if isa<RecordType>(t) {
            return self.record_layout_(cast<RecordType>(t)->decl, size, align, depth + 1)
        }

        if isa<Types::NullableType>(t) {
            return false // carries a presence flag whose placement lowering decides
        }

        if (t->size_bits == 0) || (t->align_bits == 0) || ((t->size_bits % 8) != 0) {
            return false
        }

        (*size)  = (t->size_bits / 8) as u64
        (*align) = (t->align_bits / 8) as u64
        return true
    }

    /// A struct's or plain class's layout by the C rule: each field at the
    /// next multiple of its alignment, the whole rounded up to the largest.
    /// Refuses anything the rule does not cover (bases, virtual methods,
    /// generics, layout attributes, ADT enums), so a number shown is right.
    fn record_layout_(self, d: unsafe *Decl, size: *u64, align: *u64, depth: u32) -> bool {
        if (d == &null) || (depth > 6) || decl_is_ffi(d) {
            return false
        }

        var fields: [unsafe *Decl]
        var is_union = false
        if isa<Declarations::ClassDecl>(d) {
            var unsafe *c = cast<Declarations::ClassDecl>(d)
            if (c->derives_list.size() > 0) || (c->generic_params.size() > 0) || c->is_abstract {
                return false
            }

            for var i: usize = 0; i < c->methods.size(); ++i {
                if (c->methods[i]->abi == Declarations::AbiKind::Virtual)
                    || (c->methods[i]->body_kind == Declarations::FnBodyKind::Virtual) {
                    return false // a virtual method adds a vtable pointer
                }
            }

            for var i: usize = 0; i < c->fields.size(); ++i {
                fields.push_back(unsafe (c->fields[i] as unsafe *Decl))
            }
        } else if isa<Declarations::StructDecl>(d) {
            var unsafe *c = cast<Declarations::StructDecl>(d)
            if c->generic_params.size() > 0 {
                return false
            }

            for var i: usize = 0; i < c->fields.size(); ++i {
                fields.push_back(unsafe (c->fields[i] as unsafe *Decl))
            }
        } else if isa<Declarations::UnionDecl>(d) {
            var unsafe *c = cast<Declarations::UnionDecl>(d)
            is_union = true
            for var i: usize = 0; i < c->fields.size(); ++i {
                fields.push_back(unsafe (c->fields[i] as unsafe *Decl))
            }
        } else if isa<Declarations::EnumDecl>(d) {
            var unsafe *e = cast<Declarations::EnumDecl>(d)
            if e->is_adt {
                return false
            }

            if e->underlying == &null {
                (*size)  = 4
                (*align) = 4
                return true
            }

            return self.field_layout_(e->underlying, size, align, depth + 1)
        } else {
            return false
        }

        if d->annotations.size() > 0 {
            return false // @packed / @align and friends change the rule
        }

        var off: u64 = 0
        var max: u64 = 1
        for var i: usize = 0; i < fields.size(); ++i {
            var unsafe *f = cast<Declarations::FieldDecl>(fields[i])
            if f->is_static() || f->is_bitfield {
                if f->is_bitfield {
                    return false
                }

                continue
            }

            var fs: u64 = 0
            var fa: u64 = 0
            if !self.field_layout_(f->type_, &fs, &fa, depth + 1) {
                return false
            }

            if fa > max {
                max = fa
            }

            if is_union {
                if fs > off {
                    off = fs
                }
            } else {
                off = ((off + fa - 1) / fa) * fa
                off += fs
            }
        }

        if off == 0 {
            off = 1 // an empty record still has an address
        }

        (*size)  = ((off + max - 1) / max) * max
        (*align) = max
        return true
    }

    /// "size N, align M" for a type declaration, or "" when not known.
    fn layout_(self, d: unsafe *Decl) -> string {
        if !(isa<Declarations::ClassDecl>(d) || isa<Declarations::StructDecl>(d) || isa<Declarations::UnionDecl>(d)
            || isa<Declarations::EnumDecl>(d)) {
            return ""
        }

        var size:  u64 = 0
        var align: u64 = 0
        if !self.record_layout_(d, &size, &align, 0) {
            return ""
        }

        return f"size {size} bytes, align {align}"
    }

    /// Index of \p d's hover text in `hovers`, building it on first use.
    fn hover_(self, d: unsafe *Decl) -> u32 {
        var key = (d as usize) as u64
        var hit = self.hover_of_.get(key)
        if hit != null {
            return *hit
        }

        var sig = self.signature_(d)
        var md: string = "```kairo\n"
        md += sig
        md += self.members_(d)
        md += "\n```"

        var lay = self.layout_(d)
        if !lay.empty() {
            md += "\n\n"
            md += lay
        }

        // Where it lives, when that is a type or a module: `Foo::bar` reads
        // differently from a free `bar`.
        if (d->semantic_dc != &null) && (d->semantic_dc->dc_owner != &null) {
            var unsafe *owner = d->semantic_dc->dc_owner
            var on = sema_dump_decl_name(self.ast_(), owner)
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
        self.hover_of_[key] = idx
        return idx
    }

    // --- emitting --------------------------------------------------------
}
