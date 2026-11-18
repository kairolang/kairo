/// --- The Kairo Project -------------- Analyzer/Index/CompletionItems.k --- ///
///
///   Completion items: what is in scope at the marker, members of a receiver.
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
    decl_is_ctor,
    decl_is_ffi,
    decl_is_imported,
    decl_name_tok,
    decl_pattern,
}
import AST::DeclFacts::decl_requires_clause
import AST::Mixin::Annotation::VisibilityKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    RecordType,
    builtin_for_token,
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
import AST::Node::Statements
import AST::Node::Types
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import CompletionSite::{
    Block,
    blocks_before,
    declared_in_scope,
    function_block,
}
import Diagnostic::Engine::DiagEngine
import DocumentStore::{
    LineMap,
    fnv1a,
}
import Index::Bases::*
import Index::Hovers::*
import Index::Indexer::*
import Index::Inlays::*
import Index::Legend::*
import Index::Macros::*
import Index::Primitives::primitive_consts
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
import Protocol::CIK_CONSTANT
import Sema::Check::ConformanceChecking::extension_bounds_fail
import Sema::Resolve::AccessCheck::AccessCheck
import Sema::Resolve::MemberLookup::MemberLookup
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::SemaDump::sema_dump_decl_name
import Sema::Type::TypeUtil::TypeUtil
import TextScan::{
    classify,
    is_ident_byte,
}
import Token::Token::Token
import Token::TokenKind::{
    TokenKind,
    is_keyword,
}
import Token::TokenText::TokenText

/// A method dispatched through a vtable: `virtual`, `override`, or a C++
/// virtual function (DeclImport sets the same AbiKind).
pub fn is_virtual_fn_(f: unsafe *Declarations::FunctionDecl) -> bool {
    return (f != &null)
        && ((f->abi == Declarations::AbiKind::Virtual)
            || (f->abi == Declarations::AbiKind::Override))
}

/// What a member list is asked of (IndexWalker::mode_).
pub const MEMBERS_ANY:   u32 = 0
pub const MEMBERS_VALUE: u32 = 1
pub const MEMBERS_NAMED: u32 = 2

extend IndexWalker {
    /// Whether member `d` is one the receiver's operator may name: never a
    /// constructor (a type is constructed by its own name, `T(...)`); for a
    /// value, no nested type, type alias or enum variant, which only `::`
    /// on the type names. A C++ member by its access in the header, which
    /// AccessCheck leaves to clang: never a `private:` one (Kairo code is no
    /// member or friend of a C++ class), a `protected:` one only inside a
    /// Kairo class that derives its class.
    fn member_fits_(self, d: unsafe *Decl) -> bool {
        var owner: unsafe *Decl = &null
        if (d->semantic_dc != &null) && d->semantic_dc->is_type_scope() {
            owner = d->semantic_dc->dc_owner
        }

        // A C++ member: one of an imported record (a field has no linkage
        // of its own to say so).
        var cxx = decl_is_imported(d) || ((owner != &null) && decl_is_imported(owner))
        if isa<Declarations::FunctionDecl>(d) {
            if decl_is_ctor(cast<Declarations::FunctionDecl>(d)) {
                return false
            }

            // A class template's constructor is named with its parameters
            // (`basic_string<_CharT, _Traits, _Allocator>`).
            if cxx && (owner != &null) {
                var unsafe *ctx = NameLookup::ctx_of(d)
                if ctx == &null {
                    ctx = self.ast_()
                }

                var nm = sema_dump_decl_name(ctx, d)
                var on = sema_dump_decl_name(ctx, owner)
                if (!on.is_empty()) && ((nm == on) || nm.starts_with(on + "<")) {
                    return false
                }
            }
        }

        if self.mode_ == MEMBERS_VALUE {
            if (self.context_of_decl_(d) != &null)
                || isa<Declarations::TypeAliasDecl>(d)
                || isa<Declarations::EnumVariantDecl>(d)
                || isa<Declarations::GenericParamDecl>(d) {
                return false
            }
        }

        // A type named before `::` offers its statics, nested types and
        // variants; what belongs to an object (a method that takes `self`,
        // an instance field) is offered through a value, but for the
        // methods of a type that takes part in inheritance (poly_decl_).
        if self.mode_ == MEMBERS_NAMED {
            if isa<Declarations::FunctionDecl>(d)
                && cast<Declarations::FunctionDecl>(d)->is_method()
                && (!self.named_poly_) {
                return false
            }

            if isa<Declarations::FieldDecl>(d) && (!cast<Declarations::FieldDecl>(d)->is_static()) {
                return false
            }
        }

        if !cxx {
            return true
        }

        if d->visibility == VisibilityKind::Private {
            return false
        }

        if d->visibility != VisibilityKind::Protected {
            return true
        }

        var unsafe *dc = self.cur_dc_
        while dc != &null {
            if dc->is_type_scope() && self.derives_decl_(dc->dc_owner, owner, 0) {
                return true
            }

            dc = dc->dc_parent
        }

        return false
    }

    /// Whether class `c` derives, at any depth, the record `base`.
    fn derives_decl_(self, c: unsafe *Decl, base: unsafe *Decl, depth: u32) -> bool {
        if (c == &null) || (base == &null) || (depth > 8) || (!isa<Declarations::ClassDecl>(c)) {
            return false
        }

        var unsafe *k = cast<Declarations::ClassDecl>(c)
        for var i: usize = 0; i < k->derives_list.size(); ++i {
            var unsafe *bt = self.inst_type_(k->derives_list[i].base, 0)
            if bt == &null {
                continue
            }

            var unsafe *bd = cast<RecordType>(bt)->decl
            if (bd == base)
                || (decl_pattern(bd) == base)
                || self.derives_decl_(bd, base, depth + 1) {
                return true
            }
        }

        return false
    }

    fn item_(self, d: unsafe *Decl, sort: u32) {
        if (d == &null) || d->is_implicit {
            return
        }

        var unsafe *ctx = NameLookup::ctx_of(d)
        if ctx == &null {
            ctx = self.ast_()
        }

        var name = sema_dump_decl_name(ctx, d)
        if name.is_empty() || name.starts_with("op ") || (name == completion_marker()) {
            return
        }

        // What no code can spell (a C++ deduction guide, `<deduction guide
        // for array>`) is no name to offer.
        if !is_ident_byte(name.data()[0]) {
            return
        }

        // Leading-underscore names are reserved for interop and trailing
        // underscores mark a file's private helpers: neither is something to
        // offer from another file. (A local has no file to be found
        // through, and is this file's: `var fn_` was not offered.)
        if name.starts_with("_") || name.ends_with("_") {
            var unsafe *home = NameLookup::ctx_of(d)
            if (home != &null) && (home != self.ast_()) {
                return
            }
        }

        // A member the use site may not name (`priv` from another file,
        // `prot` from outside the module and the subclasses) is not
        // offered: by AccessCheck's own verdict, the one a use would get.
        if (self.ac_ != &null)
            && ((!self.member_fits_(d)) || self.ac_->refuses(d, self.ac_through_, self.cur_fn_)) {
            return
        }

        // One item per name: overloads share a label, and the editor shows
        // the signatures once the call is typed. A namespace lists
        // thousands of names, so the first of a label is found by its hash.
        var h   = fnv1a(name)
        var hit = self.items_seen_.get(h)
        if hit != null {
            if self.items[(*hit) as usize].label == name {
                return
            }

            for var i: usize = 0; i < self.items.size(); ++i {
                if self.items[i].label == name {
                    return
                }
            }
        } else {
            self.items_seen_[h] = self.items.size() as u32
        }

        var it = ItemRow{}
        it.label  = name.copy()
        it.detail = self.signature_(d)
        it.kind   = self.item_kind_(d)
        it.sort   = sort
        // A method after `Type::` follows the statics, types and variants.
        if (self.mode_ == MEMBERS_NAMED)
            && isa<Declarations::FunctionDecl>(d)
            && cast<Declarations::FunctionDecl>(d)->is_method() {
            it.sort = 9
        }

        it.doc = self.doc_(d)
        self.items.push(it)
    }

    /// Every name declared directly in `dc`.
    fn items_of_context_(self, dc: unsafe *DeclContext, sort: u32) {
        if dc == &null {
            return
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            self.item_(*dc->dc_decls.get(i), sort)
        }
    }

    /// What a file declares at its top level, in the order it is offered.
    /// The file's DeclContext lists its functions and types; a top-level
    /// `const` / `var` is a statement of the program's item list (a
    /// DeclStmt), so both are read. One list for a completion's items and
    /// for the file's declaration table (Tables.k).
    fn tu_decls_(self, tu: unsafe *TranslationUnit, out: *[unsafe *Decl]) {
        var unsafe *dc = unsafe (tu as unsafe *DeclContext)
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            out->push(*dc->dc_decls.get(i))
        }

        if tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); i++ {
            var item = *items->get(i)
            if item.kind == TopLevelKind::Decl {
                out->push(item.as_decl())
            } else if item.kind == TopLevelKind::Stmt {
                var unsafe *st = item.as_stmt()
                if (st != &null) && isa<Statements::DeclStmt>(st) {
                    out->push(cast<Statements::DeclStmt>(st)->decl)
                }
            }
        }
    }

    /// Every name a file declares at its top level.
    fn items_of_tu_(self, tu: unsafe *TranslationUnit, sort: u32) {
        if tu == &null {
            return
        }

        var all: [unsafe *Decl]
        self.tu_decls_(tu, &all)
        for var i: usize = 0; i < all.size(); ++i {
            self.item_(all[i], sort)
        }
    }

    /// The scope a declaration opens, or null: a type's members, a module's
    /// contents.
    fn context_of_decl_(self, d: unsafe *Decl) -> unsafe *DeclContext {
        if d == &null {
            return &null
        }

        if isa<Declarations::ClassDecl>(d) {
            return unsafe (cast<Declarations::ClassDecl>(d) as unsafe *DeclContext)
        }

        if isa<Declarations::StructDecl>(d) {
            return unsafe (cast<Declarations::StructDecl>(d) as unsafe *DeclContext)
        }

        if isa<Declarations::EnumDecl>(d) {
            return unsafe (cast<Declarations::EnumDecl>(d) as unsafe *DeclContext)
        }

        if isa<Declarations::UnionDecl>(d) {
            return unsafe (cast<Declarations::UnionDecl>(d) as unsafe *DeclContext)
        }

        if isa<Declarations::InterfaceDecl>(d) {
            return unsafe (cast<Declarations::InterfaceDecl>(d) as unsafe *DeclContext)
        }

        if isa<Declarations::ModuleDecl>(d) {
            return unsafe (cast<Declarations::ModuleDecl>(d) as unsafe *DeclContext)
        }

        return &null
    }

    /// Members reachable through a value of type `t`: its record's own, then
    /// its bases'. Pointers and qualifiers are looked through, as `.` does.
    fn items_of_type_(self, t_in: unsafe *Type, depth: u32) {
        if (t_in == &null) || (depth > 8) {
            return
        }

        var unsafe *t = t_in
        if t->canonical != &null {
            t = t->canonical
        }

        t = canon_unqual(t)
        if t == &null {
            return
        }

        if isa<Types::PointerType>(t) {
            self.items_of_type_(cast<Types::PointerType>(t)->pointee, depth + 1)
            return
        }

        if isa<Types::NullableType>(t) {
            self.items_of_type_(cast<Types::NullableType>(t)->inner, depth + 1)
            return
        }

        if !isa<RecordType>(t) {
            return
        }

        var unsafe *d = cast<RecordType>(t)->decl
        self.items_of_record_(d, t, depth)
    }

    /// The record type a value of type `t_in` is, its `.` looking through
    /// pointers and `?`; null for anything else.
    fn inst_type_(self, t_in: unsafe *Type, depth: u32) -> unsafe *Type {
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
            return self.inst_type_(
                cast<Types::PointerType>(t)->pointee,
                depth + 1,
            )
        }

        if isa<Types::NullableType>(t) {
            return self.inst_type_(
                cast<Types::NullableType>(t)->inner,
                depth + 1,
            )
        }

        if isa<RecordType>(t) {
            return t
        }

        return &null
    }

    /// Whether `extend` block `e` has bounds: a `requires` clause, inline
    /// bounds of its parameters included (`__builtin_is_declared` is no part
    /// of it: DeclaredQueryFolding moves it to the block's gate).
    fn ext_bounded_(self, e: unsafe *Declarations::ExtensionDecl) -> bool {
        return (e != &null)
            && (e->methods.size() > 0)
            && (decl_requires_clause(unsafe (e as unsafe *Decl)) != &null)
    }

    /// Whether the bounds of `extend` block `e` fail for a receiver of
    /// record type `inst`: the compiler's own test of an extension member's
    /// candidacy (ConformanceChecking.k, extension_bounds_fail), asked of
    /// the block's first member, since its bounds are every member's.
    fn ext_bounds_fail_(self, e: unsafe *Declarations::ExtensionDecl, inst: unsafe *Type) -> bool {
        if (inst == &null) || (!self.ext_bounded_(e)) {
            return false
        }

        // Every declaration of one instance asks the same question.
        var key = ((e as usize as u64) * 0x9E3779B97F4A7C15) ^ (inst as usize as u64)
        var hit = self.xb_cache_.get(key)
        if hit != null {
            var k = (*hit) as usize
            if (self.xb_keys_e_[k] == (e as usize as u64))
                && (self.xb_keys_t_[k] == (inst as usize as u64)) {
                return self.xb_fails_[k]
            }
        }

        var fails = extension_bounds_fail(self.sc, e->methods[0], inst)
        if hit == null {
            self.xb_cache_[key] = self.xb_fails_.size() as u32
            self.xb_keys_e_.push(e as usize as u64)
            self.xb_keys_t_.push(inst as usize as u64)
            self.xb_fails_.push(fails)
        }

        return fails
    }

    /// The bounded `extend` blocks of the record `inst` is (its pattern's,
    /// for an instance) that this file sees, into `out`, each with whether
    /// it holds for `inst`.
    fn bounded_verdicts_(self,
                         ml:    unsafe *MemberLookup,
                         inst:  unsafe *Type,
                         out:   *[unsafe *Declarations::ExtensionDecl],
                         holds: *[bool]) {
        if (inst == &null) || (ml == &null) {
            return
        }

        var unsafe *d = cast<RecordType>(inst)->decl
        for var pass: usize = 0; pass < 2; ++pass {
            var unsafe *key = d
            if pass == 1 {
                key = decl_pattern(d)
                if (key == &null) || (key == d) {
                    break
                }
            }

            var unsafe *exts = ml->extensions_of_decl(key)
            if exts == &null {
                continue
            }

            for var i: usize = 0; i < exts->size(); ++i {
                var unsafe *e = (*exts)[i]
                if self.ext_bounded_(e) {
                    out->push(e)
                    holds->push(!self.ext_bounds_fail_(e, inst))
                }
            }
        }
    }

    /// What record, enum, interface or module `d` declares itself, in the
    /// order it is offered: what `.` and `::` can name before its bases and
    /// its extensions. The one list for a completion's items and for the
    /// file's declaration table (Tables.k), so the two cannot differ.
    fn own_members_(self, d: unsafe *Decl, out: *[unsafe *Decl]) {
        // A type keeps its members in typed lists; its DeclContext holds
        // what is nested in it. Both are what `.` and `::` can name.
        if isa<Declarations::ClassDecl>(d) {
            var unsafe *c = cast<Declarations::ClassDecl>(d)
            for var i: usize = 0; i < c->fields.size(); ++i {
                out->push(unsafe (c->fields[i] as unsafe *Decl))
            }

            for var i: usize = 0; i < c->methods.size(); ++i {
                out->push(unsafe (c->methods[i] as unsafe *Decl))
            }
        } else if isa<Declarations::StructDecl>(d) {
            var unsafe *c = cast<Declarations::StructDecl>(d)
            for var i: usize = 0; i < c->fields.size(); ++i {
                out->push(unsafe (c->fields[i] as unsafe *Decl))
            }

            for var i: usize = 0; i < c->methods.size(); ++i {
                out->push(unsafe (c->methods[i] as unsafe *Decl))
            }
        } else if isa<Declarations::UnionDecl>(d) {
            var unsafe *c = cast<Declarations::UnionDecl>(d)
            for var i: usize = 0; i < c->fields.size(); ++i {
                out->push(unsafe (c->fields[i] as unsafe *Decl))
            }

            for var i: usize = 0; i < c->methods.size(); ++i {
                out->push(unsafe (c->methods[i] as unsafe *Decl))
            }
        } else if isa<Declarations::EnumDecl>(d) {
            var unsafe *c = cast<Declarations::EnumDecl>(d)
            for var i: usize = 0; i < c->variants.size(); ++i {
                out->push(unsafe (c->variants[i] as unsafe *Decl))
            }
        } else if isa<Declarations::InterfaceDecl>(d) {
            var unsafe *c = cast<Declarations::InterfaceDecl>(d)
            for var i: usize = 0; i < c->methods.size(); ++i {
                out->push(unsafe (c->methods[i] as unsafe *Decl))
            }
        }

        var unsafe *dc = self.context_of_decl_(d)
        if dc != &null {
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                out->push(*dc->dc_decls.get(i))
            }
        }
    }

    /// The methods of the `extend` blocks of `d` that this file sees
    /// (MemberLookup's index, which applies the extension-visibility rule,
    /// a conditional block's gate included). For a value of record type
    /// `inst` (null: the type named, or the enclosing one) a block whose
    /// bounds fail for it is left out (ext_bounds_fail_).
    fn items_of_extensions_(self, d: unsafe *Decl, inst: unsafe *Type, depth: u32) {
        if self.ml_ == &null {
            return
        }

        for var pass: usize = 0; pass < 2; ++pass {
            // An instance's extensions are its pattern's.
            var unsafe *key = d
            if pass == 1 {
                key = decl_pattern(d)
                if (key == &null) || (key == d) {
                    break
                }
            }

            var unsafe *exts = self.ml_->extensions_of_decl(key)
            if exts == &null {
                continue
            }

            for var i: usize = 0; i < exts->size(); ++i {
                var unsafe *e = (*exts)[i]
                if self.ext_bounds_fail_(e, inst) {
                    continue
                }

                for var m: usize = 0; m < e->methods.size(); ++m {
                    self.item_(unsafe (e->methods[m] as unsafe *Decl), depth)
                }
            }
        }
    }

    fn items_of_record_(self, d: unsafe *Decl, inst: unsafe *Type, depth: u32) {
        if (d == &null) || (depth > 8) {
            return
        }

        if isa<Declarations::ModuleDecl>(d) {
            // A file IS a module: `import std::io` binds `io` to io.k's
            // module_self, and what the file declares lives in its TU.
            var unsafe *mctx = NameLookup::ctx_of(d)
            if (mctx != &null)
                && (mctx->tu != &null)
                && (unsafe (mctx->tu->module_self as unsafe *Decl) == d) {
                self.items_of_tu_(mctx->tu, depth)
            }
        }

        var own: [unsafe *Decl]
        self.own_members_(d, &own)
        // An instance of a generic type holds the members a use has asked
        // of it so far; its pattern declares them all, under the same
        // names. (The methods of a generic base, `RecursiveASTVisitor<X>`,
        // were missing but for the few the file had already called.) Both
        // are listed, the instance's first: an imported C++ template's
        // instance is filled by clang, and its pattern may hold less.
        var unsafe *pat = decl_pattern(d)
        if (pat != &null) && (pat != d) {
            self.own_members_(pat, &own)
        }

        for var i: usize = 0; i < own.size(); ++i {
            self.item_(own[i], depth)
        }

        if !isa<Declarations::ModuleDecl>(d) {
            self.items_of_extensions_(d, inst, depth)
        }

        if isa<Declarations::ClassDecl>(d) {
            var unsafe *c = cast<Declarations::ClassDecl>(d)
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                self.items_of_type_(c->derives_list[i].base, depth + 1)
            }
        }
    }

    /// The cursor is after `recv.` / `recv->` / `recv::` (`colons`).
    fn complete_member_(self, recv_type: unsafe *Type, recv_decl: unsafe *Decl, colons: bool) {
        self.completed = true
        var ac = AccessCheck(self.sc)
        var ml = MemberLookup(self.sc)
        self.ac_         = unsafe &ac
        self.ac_through_ = recv_type
        self.ml_         = unsafe &ml
        self.members_of_receiver_(recv_type, recv_decl, colons)
        self.ac_         = &null
        self.ac_through_ = &null
        self.ml_         = &null
    }

    /// Whether record `d` takes part in inheritance, so that its methods are
    /// named after `d::` (`Base::step(self)`): it has a base, declares a
    /// virtual or overriding method (a C++ one included), the cursor is in a
    /// class deriving it, or a class of the graph's Kairo files derives it.
    /// A C++ class derived only by another C++ class is not found by the
    /// last test.
    fn poly_decl_(self, d: unsafe *Decl) -> bool {
        if (d == &null) || isa<Declarations::ModuleDecl>(d) {
            return false
        }

        if isa<Declarations::ClassDecl>(d)
            && (cast<Declarations::ClassDecl>(d)->derives_list.size() > 0) {
            return true
        }

        var own: [unsafe *Decl]
        self.own_members_(d, &own)
        var unsafe *pat = decl_pattern(d)
        if (pat != &null) && (pat != d) {
            self.own_members_(pat, &own)
        }

        for var i: usize = 0; i < own.size(); ++i {
            if isa<Declarations::FunctionDecl>(own[i])
                && is_virtual_fn_(cast<Declarations::FunctionDecl>(own[i])) {
                return true
            }
        }

        var unsafe *dc = self.cur_dc_
        while dc != &null {
            if dc->is_type_scope() && self.derives_decl_(dc->dc_owner, d, 0) {
                return true
            }

            dc = dc->dc_parent
        }

        if self.sc->g == &null {
            return false
        }

        var fids = self.sc->g->all_fids()
        for var i: usize = 0; i < fids.size(); ++i {
            var unsafe *ctx = self.sc->g->get_context(fids[i])
            if (ctx != &null)
                && (ctx->tu != &null)
                && (!ctx->tu->is_foreign)
                && self.derived_in_(
                    unsafe (ctx->tu as unsafe *DeclContext),
                    d,
                    0,
                ) {
                return true
            }
        }

        return false
    }

    /// Whether a class declared in `dc` (in its modules and types too)
    /// derives record `base` directly.
    fn derived_in_(self, dc: unsafe *DeclContext, base: unsafe *Decl, depth: u32) -> bool {
        if (dc == &null) || (depth > 6) {
            return false
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *k = *dc->dc_decls.get(i)
            if k == &null {
                continue
            }

            if isa<Declarations::ClassDecl>(k) {
                var unsafe *c = cast<Declarations::ClassDecl>(k)
                for var b: usize = 0; b < c->derives_list.size(); ++b {
                    var unsafe *bt = self.inst_type_(c->derives_list[b].base, 0)
                    if bt != &null {
                        var unsafe *bd = cast<RecordType>(bt)->decl
                        if (bd == base) || (decl_pattern(bd) == base) {
                            return true
                        }
                    }
                }
            }

            if isa<Declarations::ModuleDecl>(k) || isa<Declarations::ClassDecl>(k) {
                if self.derived_in_(self.context_of_decl_(k), base, depth + 1) {
                    return true
                }
            }
        }

        return false
    }

    /// What a module declares, in every reopening of it (a C++ namespace is
    /// one ModuleDecl per header, linked in one redeclaration ring), with
    /// what an inline namespace among its members declares (libc++'s
    /// `std::__1`), as name lookup reaches both.
    fn items_of_namespace_(self, m: unsafe *Declarations::ModuleDecl, depth: u32) {
        if (m == &null) || (depth > 4) {
            return
        }

        var unsafe *head = m->first_decl()
        var unsafe *cur  = head
        while cur != &null {
            self.items_of_record_(unsafe (cur as unsafe *Decl), &null, 0)
            var unsafe *dc = unsafe (cur as unsafe *DeclContext)
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                var unsafe *k = *dc->dc_decls.get(i)
                if (k != &null)
                    && isa<Declarations::ModuleDecl>(k)
                    && cast<Declarations::ModuleDecl>(k)->is_inline {
                    self.items_of_namespace_(
                        cast<Declarations::ModuleDecl>(k),
                        depth + 1,
                    )
                }
            }

            cur = cur->next_in_chain()
            if cur == head {
                break
            }
        }
    }

    /// One item per name a scope's own table binds (`cxx`, whose names are
    /// in no declaration list).
    fn items_of_table_(self, dc: unsafe *DeclContext) {
        var unsafe *tbl = dc->symbols()
        if tbl == &null {
            return
        }

        var es = cxx::std::vector<SymbolTable::Entry>()
        tbl->collect_entries(&es)
        for var i: usize = 0; i < es.size(); ++i {
            if (es[i].cell != &null) && (es[i].cell->size() > 0) {
                self.item_(es[i].cell->get(0), 0)
            }
        }
    }

    /// The cursor is after `b::`, `b` a primitive (`usize::`): its
    /// associated constants, the compiler's own list (Index/Primitives.k),
    /// then the methods of the `extend` blocks of it this file sees, the
    /// statics a `b::` names among them. The index path lists the
    /// same from the tables.
    fn complete_primitive_(self, b: BuiltinKind) {
        self.completed = true
        var cs = primitive_consts(b)
        for var i: usize = 0; i < cs.size(); ++i {
            var it = ItemRow{}
            it.label                          = cs[i].name.copy()
            it.detail                         = cs[i].detail.copy()
            it.kind                           = CIK_CONSTANT as u32
            it.sort                           = 0
            self.items_seen_[fnv1a(it.label)] = self.items.size() as u32
            self.items.push(it)
        }

        if self.sc->types == &null {
            return
        }

        var ac = AccessCheck(self.sc)
        var ml = MemberLookup(self.sc)
        self.ac_ = unsafe &ac
        self.ml_ = unsafe &ml
        var unsafe *exts = ml.extensions_of_type(self.sc->types->builtin(b))
        if exts != &null {
            for var i: usize = 0; i < exts->size(); ++i {
                var unsafe *e = (*exts)[i]
                for var m: usize = 0; m < e->methods.size(); ++m {
                    self.item_(unsafe (e->methods[m] as unsafe *Decl), 0)
                }
            }
        }

        self.ac_ = &null
        self.ml_ = &null
    }

    fn members_of_receiver_(self, recv_type: unsafe *Type, recv_decl: unsafe *Decl, colons: bool) {
        // A name that IS a scope (a module, a type named for a static or a
        // variant) offers what it declares, after `::` only: `.` cannot
        // follow a type or a module (R027E). A value offers its type's
        // members.
        var unsafe *dc = self.context_of_decl_(recv_decl)
        if dc != &null {
            if !colons {
                return
            }

            self.mode_       = MEMBERS_NAMED
            self.named_poly_ = self.poly_decl_(recv_decl)
            finally {
                self.mode_       = MEMBERS_ANY
                self.named_poly_ = false
            }

            if (self.sc->tu != &null) && (recv_decl == self.sc->tu->cxx_module) {
                // `cxx::`: the module binds `std`, every reopening of it, in
                // its own table (ImportResolution, _bind_cxx).
                self.items_of_table_(dc)
                return
            }

            if isa<Declarations::ModuleDecl>(recv_decl) {
                self.items_of_namespace_(
                    cast<Declarations::ModuleDecl>(recv_decl),
                    0,
                )

                return
            }

            self.items_of_record_(recv_decl, &null, 0)
            return
        }

        self.mode_ = MEMBERS_VALUE
        finally {
            self.mode_ = MEMBERS_ANY
        }

        if recv_type != &null {
            self.items_of_type_(recv_type, 0)
            return
        }

        if recv_decl == &null {
            return
        }

        if isa<Declarations::VariableDecl>(recv_decl) {
            self.items_of_type_(
                cast<Declarations::VariableDecl>(recv_decl)->type_,
                0,
            )
        } else if isa<Declarations::ParamDecl>(recv_decl) {
            self.items_of_type_(
                cast<Declarations::ParamDecl>(recv_decl)->type_,
                0,
            )
        } else if isa<Declarations::FieldDecl>(recv_decl) {
            self.items_of_type_(
                cast<Declarations::FieldDecl>(recv_decl)->type_,
                0,
            )
        }
    }

    /// The cursor (the marker, at byte `at` of the file) is on a bare
    /// name: locals, then the enclosing type, then the file, then what the
    /// file imports.
    fn complete_scope_(self, at: u32) {
        self.completed = true

        // The locals still in scope at the marker: the walk has met every
        // local of the function so far, those of blocks that have closed
        // too. Which blocks are open is read off the text, by the index
        // path's own test, so the two lists agree.
        var blocks: [Block]
        var fi:     usize   = 0
        if at != u32::MAX {
            var *ft = &self.files[self.file_(self.fid)]
            var cls = classify(ft->text)
            blocks = blocks_before(ft->text, cls, at as usize)
            fi     = function_block(blocks)
            if fi == usize::MAX {
                fi = 0
            }
        }

        var n = self.locals_.size()
        for var i: usize = 0; i < n; ++i {
            var k = n - 1 - i
            if (at != u32::MAX) && (!declared_in_scope(blocks, fi, self.locals_at_[k] as usize)) {
                continue
            }

            self.item_(self.locals_[k], 0)
        }

        if self.cur_dc_ != &null {
            var ac = AccessCheck(self.sc)
            var ml = MemberLookup(self.sc)
            self.ac_ = unsafe &ac
            self.ml_ = unsafe &ml
            var unsafe *dc = self.cur_dc_
            while dc != &null {
                if dc->is_type_scope() {
                    self.items_of_record_(dc->dc_owner, &null, 1)
                }

                dc = dc->dc_parent
            }

            self.ac_ = &null
            self.ml_ = &null
        }

        var unsafe *tu = self.sc->tu
        if tu == &null {
            return
        }

        for var i: usize = 0; i < self.globals_.size(); ++i {
            var unsafe *g = self.globals_[i]
            if (g->semantic_dc == &null) || (!g->semantic_dc->is_type_scope()) {
                self.item_(g, 2)
            }
        }

        self.items_of_tu_(tu, 2)

        // Imported names: the overlay is the table name resolution itself
        // reads, so this is exactly the set an unqualified name can reach.
        if tu->import_overlay != &null {
            self.overlay_rows_(tu, true)
        }
    }
}
