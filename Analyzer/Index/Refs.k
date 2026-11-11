/// --- The Kairo Project ------------------------- Analyzer/Index/Refs.k --- ///
///
///   References: what a name use points at, declarations, imports, call-site modifiers.
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
import AST::AttrFacts::AttrFacts
import AST::DeclFacts::{
    decl_extension_of,
    decl_is_ffi,
    decl_pattern,
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
import AST::LangItems::LangAttrs
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
import Index::Hovers::*
import Index::Indexer::*
import Index::Inlays::*
import Index::Legend::*
import Index::Macros::*
import Index::Tokens::*
import Index::Writer::*

extend IndexWalker {
    /// The type a constructor constructs, or null when \p d is not one. A
    /// constructor is a function declared in a type under the type's name.
    fn ctor_owner_(self, d: unsafe *Decl) -> unsafe *Decl {
        if (d == &null) || (!isa<Declarations::FunctionDecl>(d)) || (d->semantic_dc == &null) {
            return &null
        }

        var unsafe *f = cast<Declarations::FunctionDecl>(d)
        if f->is_operator || (!d->semantic_dc->is_type_scope()) || (!f->name.range.start.is_valid()) {
            return &null
        }

        var unsafe *owner = d->semantic_dc->dc_owner
        if owner == &null {
            return &null
        }

        var unsafe *ctx = NameLookup::ctx_of(d)
        if ctx == &null {
            return &null
        }

        if ctx->get_spelling(f->name) != sema_dump_decl_name(ctx, owner) {
            return &null
        }

        return owner
    }

    /// Fills \p r's definition half from \p d.
    fn target_(self, d: unsafe *Decl, r: *RefRow) {
        r->hover = self.hover_(d)
        r->kind  = self.kind_of_(d)

        var name = decl_name_tok(d)
        var at   = name.range
        if isa<Declarations::FunctionDecl>(d) {
            var unsafe *f = cast<Declarations::FunctionDecl>(d)
            if f->is_operator && (f->op_token.size() > 0) {
                at = f->op_token[0].range
            }
        }

        // A constructor's name IS the type's name: it is one symbol to rename,
        // to highlight and to find references of. Its row points at the type
        // (the hover above stays the constructor's own signature).
        var unsafe *owner = self.ctor_owner_(d)
        if owner != &null {
            var on = decl_name_tok(owner).range
            if on.start.is_valid() {
                at = on
            }
        }

        if !at.start.is_valid() {
            at = d->range
        }

        if !at.start.is_valid() {
            return
        }

        var res = self.sm->resolve(at.start)
        r->def_fid = res.fid as u32
        r->def_off = res.offset as u32
        r->def_len = at.size() as u32
        if r->def_len > 4096 {
            // Fell back to a whole-declaration range: point at its start.
            r->def_len = 0
        }

        var unsafe *td = self.type_decl_(self.value_type_(d), 0)
        if td != &null {
            var tn = decl_name_tok(td).range
            if tn.start.is_valid() {
                var tres = self.sm->resolve(tn.start)
                r->type_fid = tres.fid as u32
                r->type_off = tres.offset as u32
                r->type_len = tn.size() as u32
            }
        }
    }

    /// The type a use of \p d has: a variable's, a field's, a parameter's, or
    /// what a function returns. Null for a declaration that IS a type.
    fn value_type_(self, d: unsafe *Decl) -> unsafe *Type {
        if isa<Declarations::VariableDecl>(d) {
            return cast<Declarations::VariableDecl>(d)->type_
        }

        if isa<Declarations::ParamDecl>(d) {
            return cast<Declarations::ParamDecl>(d)->type_
        }

        if isa<Declarations::FieldDecl>(d) {
            return cast<Declarations::FieldDecl>(d)->type_
        }

        if isa<Declarations::FunctionDecl>(d) {
            return cast<Declarations::FunctionDecl>(d)->return_type
        }

        return &null
    }

    /// The record a type names, through pointers and `?`. Null for a builtin.
    fn type_decl_(self, t_in: unsafe *Type, depth: u32) -> unsafe *Decl {
        if (t_in == &null) || (depth > 8) {
            return &null
        }

        var unsafe *t = t_in
        if t->canonical != &null {
            t = t->canonical
        }

        t = canon_unqual(t)
        if t == &null {
            return &null
        }

        if isa<Types::PointerType>(t) {
            return self.type_decl_(cast<Types::PointerType>(t)->pointee, depth + 1)
        }

        if isa<Types::NullableType>(t) {
            return self.type_decl_(cast<Types::NullableType>(t)->inner, depth + 1)
        }

        if isa<RecordType>(t) {
            return cast<RecordType>(t)->decl
        }

        return &null
    }

    /// Records the declaration \p d itself: its token, a self-edge (so hover
    /// and highlight work on a declaration), and its outline row.
    fn declare_(self, d: unsafe *Decl) {
        if (d == &null) || d->is_implicit {
            return
        }

        var kind = self.kind_of_(d)
        if kind == TT_NONE() {
            return
        }

        var name = self.ast_()->unwrap_token(decl_name_tok(d))
        var off  = self.own_off_(name.range.start)
        if off == u32::MAX {
            return
        }

        var len = name.range.size() as u32
        if len == 0 {
            return
        }

        var mods = self.mods_of_(d) | TM_DECLARATION() | TM_DEFINITION()
        var is_ctor = self.ctor_owner_(d) != &null
        if is_ctor {
            // Reads as the type it names, marked as a constructor.
            kind = self.kind_of_(self.ctor_owner_(d))
            mods = (self.mods_of_(d) | TM_CONSTRUCTOR() | TM_DECLARATION()) & (~TM_STATIC())
        }

        self.tok_(off, len, kind, mods)

        var r = RefRow{}
        r.off     = off
        r.len     = len
        // A constructor is a USE of the type's name, not its declaration:
        // "references, excluding the declaration" must list it.
        r.is_decl = !is_ctor
        self.target_(d, &r)
        self.refs.push_back(r)

        // The outline lists what a reader navigates to: not parameters, not
        // locals, not type parameters.
        if (kind == TT_PARAMETER()) || (kind == TT_SELF()) || (kind == TT_TYPE_PARAM()) {
            self.locals_.push_back(d)
            return
        }

        // Anything not declared straight into a file, a module or a type is a
        // local: a function body, a closure, a block.
        var local = true
        if d->semantic_dc != &null {
            var k = d->semantic_dc->dc_kind
            local = !((k == DeclContextKind::TranslationUnit) || (k == DeclContextKind::Module)
                || d->semantic_dc->is_type_scope())
        }

        if local {
            self.locals_.push_back(d)
            return
        }

        var s = SymRow{}
        s.name    = self.ast_()->get_spelling(name)
        s.kind    = self.symbol_kind_(d)
        s.sel_off = off
        s.sel_len = len
        s.start   = off
        s.end     = off + len
        var ds = self.own_off_(d->range.start)
        var de = self.own_off_(d->range.end)
        if (ds != u32::MAX) && (de != u32::MAX) && (ds <= off) && (de >= (off + len)) {
            s.start = ds
            s.end   = de
        }

        if isa<Declarations::FunctionDecl>(d) {
            s.detail = self.signature_(d)
        }

        if is_ctor {
            s.kind = 9 // LSP SymbolKind.Constructor
        }

        if s.kind != 0 {
            self.syms.push_back(s)
        }

        self.globals_.push_back(d)
    }

    /// The declaration an import binds under \p bound, recorded as a use at
    /// \p shown (and at the alias, when the two differ). False when the
    /// overlay binds nothing there, or a module.
    fn import_name_(self, bound: Token, shown: Token) -> bool {
        if (self.sc == &null) || (self.sc->tu == &null) || (self.sc->tu->import_overlay == &null) {
            return false
        }

        var unsafe *cell = self.sc->tu->import_overlay->lookup_ident(self.ast_()->get_ident_imm(bound))
        if (cell == &null) || (cell->size() == 0) {
            return false
        }

        var unsafe *d = cell->get(0)
        if (d == &null) || isa<Declarations::ModuleDecl>(d) || isa<Declarations::ImportDecl>(d) {
            return false
        }

        self.use_(shown, d, 0)
        if bound.range.start.raw() != shown.range.start.raw() {
            self.use_(bound, d, 0)
        }

        return true
    }

    /// `import a::b::c`: each segment is a namespace token.
    /// A header string's spelling without its `"..."` or `<...>`.
    fn unquote_(self, const lit: string) -> string {
        if lit.size() < 2 {
            return lit
        }

        var a = lit[0]
        var z = lit[lit.size() - 1]
        if ((a == 34) && (z == 34)) || ((a == 60) && (z == 62)) {
            return lit.subslice(1, lit.size() - 2)
        }

        return lit
    }

    fn import_(self, d: unsafe *Decl) {
        if (d == &null) || (!isa<Declarations::ImportDecl>(d)) {
            return
        }

        var unsafe *im = cast<Declarations::ImportDecl>(d)
        if im->is_prelude {
            return
        }

        // The last segment of `import std::io::println` names a declaration,
        // not a module, when the overlay binds it to one: then it is a use of
        // that declaration (its colour, and a jump), like a listed item.
        var n_seg = im->path_segments.size()
        for var i: usize = 0; i < n_seg; ++i {
            var t = im->path_segments[i]
            if ((i + 1) == n_seg) && (!im->has_items) && (!im->is_wildcard) && (!im->last_seg_is_macro)
                && self.import_name_(if (im->has_alias) => (im->alias) else => t, t) {
                continue
            }

            self.tok_(self.own_off_(t.range.start), t.range.size() as u32, TT_NAMESPACE(), 0)
        }

        // `import a::b::{X, sub::Y as Z}`: the leading words of an item are
        // modules; its last is the declaration the file gets, bound under
        // the alias when there is one.
        for var i: usize = 0; i < im->items.size(); ++i {
            var it = im->items[i]
            if it.is_wildcard || it.is_macro || (it.sub_path.size() == 0) {
                continue
            }

            var last = it.sub_path[it.sub_path.size() - 1]
            for var k: usize = 0; (k + 1) < it.sub_path.size(); ++k {
                var t = it.sub_path[k]
                self.tok_(self.own_off_(t.range.start), t.range.size() as u32, TT_NAMESPACE(), 0)
            }

            if !self.import_name_(if (it.has_alias) => (it.alias) else => last, last) {
                // A module brought in by name (`io::{fs}`).
                self.tok_(self.own_off_(last.range.start), last.range.size() as u32, TT_NAMESPACE(), 0)
            }
        }


        // An ffi import's header string is a link to the header clang
        // resolved, as clangd links an `#include`. The driver stamps the
        // header's own fid as resolved_fid (FrontendAction::_attach_ffi_edges:
        // the first of its include closure that has a fid), or 0 when clang
        // never found it. Should the header itself have no fid, the first
        // of the closure is one of ITS includes: the path must end in the
        // spelling, or the link would open the wrong file.
        if im->has_ffi_linkage() {
            if (im->resolved_fid != 0) && (im->resolved_fid != u32::MAX) {
                var hoff   = self.own_off_(im->header.range.start)
                var hlen   = im->header.range.size() as u32
                var hdr    = self.unquote_(self.ast_()->get_spelling(im->header))
                var target = self.sm->get_filename(im->resolved_fid)
                if (hoff != u32::MAX) && (hlen > 0) && (!hdr.empty()) && target.ends_with("/" + hdr) {
                    var row = LinkRow{}
                    row.off    = hoff
                    row.len    = hlen
                    row.target = target
                    self.links.push_back(row)
                }
            }

            return
        }

        // The path is a link to the file it resolved to.
        if (im->import_kind == Declarations::ImportKind::Native) && (im->path_segments.size() > 0)
            && (im->resolved_fid != 0) && (im->resolved_fid != u32::MAX) {
            var first = im->path_segments[0].range.start
            var last  = im->path_segments[im->path_segments.size() - 1].range.end
            var off   = self.own_off_(first)
            var target = self.sm->get_filename(im->resolved_fid)
            if (off != u32::MAX) && (!target.empty()) && (last.raw() > first.raw()) {
                var row = LinkRow{}
                row.off    = off
                row.len    = last.raw() - first.raw()
                row.target = target
                self.links.push_back(row)
            }
        }
    }

    // --- overloads -------------------------------------------------------

    /// True when \p f shares its name with another declaration in its scope.
    fn is_overloaded_(self, f: unsafe *Declarations::FunctionDecl) -> bool {
        var unsafe *d = unsafe (f as unsafe *Decl)
        if (d->semantic_dc == &null) || (d->semantic_dc->dc_symbols == &null) {
            return false
        }

        var unsafe *ctx = NameLookup::ctx_of(d)
        if ctx == &null {
            return false
        }

        if f->is_operator {
            return false
        }

        var unsafe *cell = d->semantic_dc->dc_symbols->lookup(DeclName::ident(ctx->get_ident_imm(f->name)))
        if cell == &null {
            return false
        }

        return cell->size() > 1
    }

    /// Adds the call-site modifiers for callee \p d at name token \p tok.
    fn mark_call_(self, tok_in: Token, d: unsafe *Decl) {
        if (d == &null) || (!isa<Declarations::FunctionDecl>(d)) {
            return
        }

        var unsafe *f = cast<Declarations::FunctionDecl>(d)
        var m: u32 = 0
        if f->where_lead != &null {
            m = m | TM_DISPATCHED()
        }

        // A `requires` clause makes the callee one of a constrained family:
        // which body runs was decided by the clause, as with an overload.
        if self.is_overloaded_(f) || (decl_requires_clause(d) != &null) {
            m = m | TM_OVERLOADED()
        }

        if decl_extension_of(d) != &null {
            m = m | TM_EXTENSION()
        }

        // Style rule 2: an extension or C/C++ call is italic, never also
        // underlined; overloading says little there.
        if ((m & TM_EXTENSION()) != 0) || decl_is_ffi(d) {
            m = m & (~TM_OVERLOADED())
        }

        if f->is_unsafe() {
            m = m | TM_UNSAFE()
        }

        if f->is_panic() {
            m = m | TM_PANICS()
        }

        if m == 0 {
            return
        }

        var tok = self.ast_()->unwrap_token(tok_in)
        var off = self.own_off_(tok.range.start)
        if off == u32::MAX {
            return
        }

        var cur = self.extra_mods_.get(off)
        if cur != null {
            m = m | *cur
        }

        self.extra_mods_[off] = m
    }

    /// Adds \p m to the token at \p tok_in, an operator the lexical pass
    /// leaves unclassified: it becomes an `operator` token carrying \p m.
    fn op_mod_(self, tok_in: Token, m: u32) {
        var tok = self.ast_()->unwrap_token(tok_in)
        var off = self.own_off_(tok.range.start)
        if off == u32::MAX {
            return
        }

        var cur = self.extra_mods_.get(off)
        if cur != null {
            self.extra_mods_[off] = *cur | m
            return
        }

        self.extra_mods_[off] = m
        self.tok_(off, tok.range.size() as u32, TT_OPERATOR(), 0)
    }

    /// `mutates` on the `&` of each argument through which call \p c may
    /// write: an `@inout` marker, or `&x` of a mutable `x` bound to a
    /// pointer parameter (the pointee\x27s constness is not read).
    fn mark_mutates_(self, c: unsafe *Expressions::CallExpr, d: unsafe *Decl) {
        if (d == &null) || (!isa<Declarations::FunctionDecl>(d)) {
            return
        }

        var unsafe *f = cast<Declarations::FunctionDecl>(d)
        var skip: usize = 0
        if (f->params.size() > 0) && f->params[0]->is_self {
            skip = 1
        }

        for var i: usize = 0; i < c->args.size(); ++i {
            var unsafe *arg = c->args[i]
            if (arg == &null) || (!isa<Expressions::UnaryOperatorExpr>(arg)) {
                continue
            }

            var unsafe *u = cast<Expressions::UnaryOperatorExpr>(arg)
            if (u->op_token.kind as u32) != (TokenKind::OpAmp as u32) {
                continue
            }

            var hit = u->is_mode_marker
            var pi = i + skip
            if (!hit) && (pi < f->params.size()) && (u->operand != &null) && isa<NamedIdentExpr>(u->operand) {
                var unsafe *pt = f->params[pi]->type_
                var unsafe *v  = cast<NamedIdentExpr>(u->operand)->resolved_decl
                hit = (pt != &null) && isa<Types::PointerType>(pt) && (v != &null)
                   && ((self.mods_of_(v) & TM_MUTABLE()) != 0)
            }

            if hit {
                self.op_mod_(u->op_token, TM_MUTATES())
            }
        }
    }

    /// A user-defined operator at \p tok: an operator token that reads as a
    /// call, and jumps to the `op` function.
    fn user_op_(self, tok: Token, d: unsafe *Decl) {
        if d == &null {
            return
        }

        var off = self.own_off_(tok.range.start)
        if off == u32::MAX {
            return
        }

        var len = tok.range.size() as u32
        var m   = TM_OVERLOADED()
        if decl_extension_of(d) != &null {
            // An operator an `extend` block supplies reads as an extension
            // call (italic in the clients), not as the type's own overload.
            m = TM_EXTENSION()
        }

        if isa<Declarations::FunctionDecl>(d) && (cast<Declarations::FunctionDecl>(d)->where_lead != &null) {
            m = m | TM_DISPATCHED()
        }

        self.tok_(off, len, TT_OPERATOR(), m)

        var r = RefRow{}
        r.off = off
        r.len = len
        self.target_(d, &r)
        self.refs.push_back(r)
    }

    // --- completion ------------------------------------------------------

    fn is_marker_(self, n: unsafe *NamedIdentExpr) -> bool {
        if n == &null {
            return false
        }

        return self.ast_()->get_spelling(n->name) == completion_marker()
    }

    fn overlay_rows_(self, tu: unsafe *TranslationUnit) {
        // A std::vector because ImportOverlay::collect_rows fills one: the
        // compiler's signature, not a choice made here.
        var all: cxx::std::vector<ImportOverlay::Row>
        tu->import_overlay->collect_rows(&all)
        for var i: usize = 0; i < all.size(); ++i {
            var unsafe *e = all[i].entry
            if e == &null {
                continue
            }

            for var k: usize = 0; k < e->targets.size(); ++k {
                if e->targets[k].hidden || (e->targets[k].vis != OverlayVisibility::Public) {
                    continue
                }

                // What the file imported by name comes before what the
                // builtin prelude brings into every file.
                var sort: u32 = 3
                if (e->targets[k].origin != &null) && e->targets[k].origin->is_prelude {
                    sort = 4
                }

                if e->targets[k].decl != &null {
                    self.item_(e->targets[k].decl, sort)
                } else if (e->targets[k].cell != &null) && (e->targets[k].cell->size() > 0) {
                    self.item_(e->targets[k].cell->get(0), sort)
                }
            }
        }
    }

    // --- visits ----------------------------------------------------------
}
