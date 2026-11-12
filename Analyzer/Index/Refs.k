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


ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::AttrFacts::AttrFacts
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
    decl_is_ffi,
    decl_name_tok,
    decl_pattern,
    decl_requires_clause,
}
import AST::LangItems::LangAttrs
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_has_const,
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
import Index::Bases::*
import Index::CompletionItems::*
import Index::Hovers::*
import Index::Indexer::*
import Index::Inlays::*
import Index::Legend::*
import Index::Macros::*
import Index::Snapshot::*
import Index::Tables::*
import Index::Tokens::*
import Index::Writer::*
import Json::JsonWriter
import Lexer::Immediate::ImmediateTable
import Lexer::Lexer::Lexer
import Location::SourceLocation::SourceLocation
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Protocol::*
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

extend IndexWalker {
    /// The type a constructor constructs, or null when \p d is not one. A
    /// constructor is a function declared in a type under the type's name.
    fn ctor_owner_(self, d: unsafe *Decl) -> unsafe *Decl {
        if (d == &null) || (!isa<Declarations::FunctionDecl>(d)) || (d->semantic_dc == &null) {
            return &null
        }

        var unsafe *f = cast<Declarations::FunctionDecl>(d)
        if f->is_operator
            || (!d->semantic_dc->is_type_scope())
            || (!f->name.range.start.is_valid()) {
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

    /// What a subscript of a value of type \p t_in is: the element of a
    /// `[T]`, `[T; N]`, `[T;]`, the value of a `{K: V}`. Null for anything
    /// else: a pointer's or a nullable's subscript is not `v[i]` of the
    /// value, and a type's own `op []` is not read here.
    fn elem_type_(self, t_in: unsafe *Type) -> unsafe *Type {
        for var pass: usize = 0; pass < 2; ++pass {
            var unsafe *t = t_in
            if (pass == 1) && (t != &null) {
                t = t->canonical
            }

            t = canon_unqual(t)
            if t == &null {
                continue
            }

            if isa<Types::VectorType>(t) {
                return cast<Types::VectorType>(t)->element
            }

            if isa<Types::FixedArrayType>(t) {
                return cast<Types::FixedArrayType>(t)->element
            }

            if isa<Types::MapType>(t) {
                return cast<Types::MapType>(t)->value
            }
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
            return self.type_decl_(
                cast<Types::PointerType>(t)->pointee,
                depth + 1,
            )
        }

        if isa<Types::NullableType>(t) {
            return self.type_decl_(
                cast<Types::NullableType>(t)->inner,
                depth + 1,
            )
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

        var mods    = self.mods_of_(d) | TM_DECLARATION() | TM_DEFINITION()
        var is_ctor = self.ctor_owner_(d) != &null
        if is_ctor {
            // Reads as the type it names, marked as a constructor.
            kind = self.kind_of_(self.ctor_owner_(d))
            mods = (self.mods_of_(d) | TM_CONSTRUCTOR() | TM_DECLARATION()) & (~TM_STATIC())
        }

        self.tok_(off, len, kind, mods)

        var r = RefRow{}
        r.off = off
        r.len = len
        // A constructor is a USE of the type's name, not its declaration:
        // "references, excluding the declaration" must list it.
        r.is_decl = !is_ctor
        self.target_(d, &r)
        self.refs.push_back(r)

        // The outline lists what a reader navigates to: not parameters, not
        // locals, not type parameters.
        if (kind == TT_PARAMETER()) || (kind == TT_SELF()) || (kind == TT_TYPE_PARAM()) {
            self.locals_.push_back(d)
            self.locals_at_.push_back(off)
            return
        }

        // Anything not declared straight into a file, a module or a type is a
        // local: a function body, a closure, a block.
        var local = true
        if d->semantic_dc != &null {
            var k = d->semantic_dc->dc_kind
            local = !((k == DeclContextKind::TranslationUnit)
                || (k == DeclContextKind::Module)
                || d->semantic_dc->is_type_scope())
        }

        if local {
            self.locals_.push_back(d)
            self.locals_at_.push_back(off)
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
            s.kind = SYM_CONSTRUCTOR as u32
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

        var unsafe *cell = self.sc->tu->import_overlay->lookup_ident(
            self.ast_()->get_ident_imm(bound),
        )

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
        if ((a == ('"' as u8)) && (z == ('"' as u8)))
            || ((a == ('<' as u8)) && (z == ('>' as u8))) {
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
            if ((i + 1) == n_seg)
                && (!im->has_items)
                && (!im->is_wildcard)
                && (!im->last_seg_is_macro)
                && self.import_name_(
                    if (im->has_alias) => (im->alias) else => t,
                    t,
                ) {
                continue
            }

            self.tok_(
                self.own_off_(t.range.start),
                t.range.size() as u32,
                TT_NAMESPACE(),
                0,
            )
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
                self.tok_(
                    self.own_off_(t.range.start),
                    t.range.size() as u32,
                    TT_NAMESPACE(),
                    0,
                )
            }

            if !self.import_name_(
                if (it.has_alias) => (it.alias) else => last,
                last,
            ) {
                // A module brought in by name (`io::{fs}`).
                self.tok_(
                    self.own_off_(last.range.start),
                    last.range.size() as u32,
                    TT_NAMESPACE(),
                    0,
                )
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
                var hoff = self.own_off_(im->header.range.start)
                var hlen = im->header.range.size() as u32
                var hdr = self.unquote_(self.ast_()->get_spelling(im->header))
                var target = self.sm->get_filename(im->resolved_fid)
                if (hoff != u32::MAX)
                    && (hlen > 0)
                    && (!hdr.empty())
                    && target.ends_with("/" + hdr) {
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
        if (im->import_kind == Declarations::ImportKind::Native)
            && (im->path_segments.size() > 0)
            && (im->resolved_fid != 0)
            && (im->resolved_fid != u32::MAX) {
            var first = im->path_segments[0].range.start
            var last = im->path_segments[im->path_segments.size() - 1].range.end
            var off    = self.own_off_(first)
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

        var unsafe *cell = d->semantic_dc->dc_symbols->lookup(
            DeclName::ident(ctx->get_ident_imm(f->name)),
        )

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

        var unsafe *f     = cast<Declarations::FunctionDecl>(d)
        var        m: u32 = 0
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

    /// The `&` written for argument \p e_in: the address-of or `@inout`
    /// marker beneath a named argument's label, parentheses and `unsafe`;
    /// null when the argument is anything else.
    fn arg_amp_(self, e_in: unsafe *Expr) -> unsafe *Expressions::UnaryOperatorExpr {
        var unsafe *e = e_in
        while e != &null {
            if isa<Expressions::NamedArgExpr>(e) {
                e = cast<Expressions::NamedArgExpr>(e)->value
            } else if isa<Expressions::ParenExpr>(e) {
                e = cast<Expressions::ParenExpr>(e)->inner
            } else if isa<Expressions::UnsafeExpr>(e) {
                e = cast<Expressions::UnsafeExpr>(e)->operand
            } else {
                break
            }
        }

        if (e == &null) || (!isa<Expressions::UnaryOperatorExpr>(e)) {
            return &null
        }

        var unsafe *u = cast<Expressions::UnaryOperatorExpr>(e)
        if (u->op_token.kind as u32) != (TokenKind::OpAmp as u32) {
            return &null
        }

        return u
    }

    /// \p t is a `const T` (a canonical's qualifier or a written `const`).
    fn is_const_type_(self, t: unsafe *Type) -> bool {
        return (t != &null) && (canon_has_const(t) || t->is_const())
    }

    /// What the `&` of an argument passed to a parameter of type \p t_in
    /// tells the reader: `pointer` for a pointer (through a `?`), with
    /// `unsafe` for `unsafe *T` and `readonly` for a const pointee;
    /// `inout` + `mutates` for a C++ `T&`. 0 for any other type, which takes
    /// no `&` (a C++ `const T&` is passed as `x: T`). The canonical type is
    /// read first, so an alias of a pointer is a pointer; a dependent type
    /// has none and is read as written.
    fn amp_kind_(self, t_in: unsafe *Type) -> u32 {
        if t_in == &null {
            return 0
        }

        var unsafe *t = t_in
        if t->canonical != &null {
            t = t->canonical
        }

        t = canon_unqual(t)
        if (t != &null) && isa<Types::NullableType>(t) {
            t = canon_unqual(cast<Types::NullableType>(t)->inner)
        }

        if t == &null {
            return 0
        }

        if isa<Types::CXXLValueRefType>(t) {
            if self.is_const_type_(cast<Types::CXXLValueRefType>(t)->referee) {
                return 0
            }

            return TM_INOUT() | TM_MUTATES()
        }

        if !isa<Types::PointerType>(t) {
            return 0
        }

        var unsafe *pt     = cast<Types::PointerType>(t)
        var        m:  u32 = TM_POINTER()
        if pt->is_unsafe {
            m = m | TM_UNSAFE()
        }

        if self.is_const_type_(pt->pointee) {
            m = m | TM_READONLY()
        }

        return m
    }

    /// `&e` passed to a `*T` is the address of a place the call may write:
    /// Sema accepted a `*T`, so only a `&e` typed `*const T` (a call that
    /// did not check) or the address of a binding that is not mutable is
    /// not one.
    fn writable_place_(self, u: unsafe *Expressions::UnaryOperatorExpr) -> bool {
        var unsafe *t = u->type_
        if (t != &null) && (t->canonical != &null) {
            t = t->canonical
        }

        t = canon_unqual(t)
        if (t != &null)
            && isa<Types::PointerType>(t)
            && self.is_const_type_(cast<Types::PointerType>(t)->pointee) {
            return false
        }

        var unsafe *e = u->operand
        while (e != &null) && isa<Expressions::ParenExpr>(e) {
            e = cast<Expressions::ParenExpr>(e)->inner
        }

        if (e != &null) && isa<NamedIdentExpr>(e) {
            var unsafe *v = cast<NamedIdentExpr>(e)->resolved_decl
            if (v == &null)
                || (isa<Declarations::VariableDecl>(v)
                    && ((self.mods_of_(v) & TM_MUTABLE()) == 0)) {
                return false
            }
        }

        return true
    }

    /// Tags the `&` of each argument of call \p c by the parameter of callee
    /// \p d it binds to (style table): `inout` + `mutates` for an `@inout`
    /// parameter or a C++ `T&`; `pointer` (+ `mutates` for a writable place)
    /// for `*T`; `pointer` + `unsafe` for `unsafe *T`; `pointer` + `readonly`
    /// for `*const T`, never `mutates`. The arguments are matched to the
    /// parameters through the call's `arg_map`, so a named or reordered
    /// argument is tagged by its own parameter; a call Sema did not map
    /// falls back to position. A pack parameter's arguments, a C variadic's
    /// extra arguments and a call with no selected callee are not tagged.
    fn mark_amps_(self, c: unsafe *Expressions::CallExpr, d: unsafe *Decl) {
        if (d == &null) || (!isa<Declarations::FunctionDecl>(d)) {
            return
        }

        var unsafe *f           = cast<Declarations::FunctionDecl>(d)
        var        n            = f->params.size()
        var        mapped       = c->arg_map.size() == n
        var        skip:  usize = 0
        if (n > 0) && f->params[0]->is_self {
            skip = 1
        }

        for var pi: usize = 0; pi < n; ++pi {
            var unsafe *p = f->params[pi]
            if (p == &null) || p->is_self {
                continue
            }

            if p->is_pack {
                if mapped {
                    continue
                }

                break
            }

            var ai: i64 = (pi as i64) - (skip as i64)
            if mapped {
                ai = c->arg_map[pi] as i64
            }

            if (ai < 0) || (ai >= (c->args.size() as i64)) {
                continue
            }

            var unsafe *arg = c->args[ai as usize]
            if (!mapped) && (arg != &null) && isa<Expressions::NamedArgExpr>(arg) {
                continue
            }

            var unsafe *u = self.arg_amp_(arg)
            if u == &null {
                continue
            }

            var m: u32 = 0
            if u->is_mode_marker || p->is_inout() {
                m = TM_INOUT() | TM_MUTATES()
            } else {
                m = self.amp_kind_(p->type_)
                if (m == TM_POINTER()) && self.writable_place_(u) {
                    m = m | TM_MUTATES()
                }
            }

            if m != 0 {
                self.op_mod_(u->op_token, m)
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

        if isa<Declarations::FunctionDecl>(d)
            && (cast<Declarations::FunctionDecl>(d)->where_lead != &null) {
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

    /// \p as_items: each is a completion item (the marker's list); else a
    /// scope row of the file's block (Tables.k), the same names in the same
    /// order.
    fn overlay_rows_(self, tu: unsafe *TranslationUnit, as_items: bool) {
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

                var d: unsafe *Decl = e->targets[k].decl
                if (d == &null)
                    && (e->targets[k].cell != &null)
                    && (e->targets[k].cell->size() > 0) {
                    d = e->targets[k].cell->get(0)
                }

                if as_items {
                    self.item_(d, sort)
                } else {
                    self.scope_row_(d, sort)
                }
            }
        }
    }

    // --- visits ----------------------------------------------------------
}
