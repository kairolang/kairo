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


import Index::Snapshot::*
import CompletionSite::{
    Block,
    blocks_before,
    declared_in_scope,
    function_block,
}
import TextScan::classify
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
    decl_pattern,
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
import AST::Node::Statements
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
import Sema::Resolve::AccessCheck::AccessCheck
import Sema::Resolve::MemberLookup::MemberLookup
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
import Index::Hovers::*
import Index::Indexer::*
import Index::Inlays::*
import Index::Legend::*
import Index::Macros::*
import Index::Refs::*
import Index::Tokens::*
import Index::Writer::*

extend IndexWalker {
    fn item_(self, d: unsafe *Decl, sort: u32) {
        if (d == &null) || d->is_implicit {
            return
        }

        var unsafe *ctx = NameLookup::ctx_of(d)
        if ctx == &null {
            ctx = self.ast_()
        }

        var name = sema_dump_decl_name(ctx, d)
        if name.empty() || name.starts_with("op ") || (name == completion_marker()) {
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
        if (self.ac_ != &null) && self.ac_->refuses(d, self.ac_through_, self.cur_fn_) {
            return
        }

        // One item per name: overloads share a label, and the editor shows
        // the signatures once the call is typed.
        for var i: usize = 0; i < self.items.size(); ++i {
            if self.items[i].label == name {
                return
            }
        }

        var it = ItemRow{}
        it.label  = name
        it.detail = self.signature_(d)
        it.kind   = self.item_kind_(d)
        it.sort   = sort
        it.doc    = self.doc_(d)
        self.items.push_back(it)
    }

    /// Every name declared directly in \p dc.
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
            out->push_back(*dc->dc_decls.get(i))
        }

        if tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); i++ {
            var item = *items->get(i)
            if item.kind == TopLevelKind::Decl {
                out->push_back(item.as_decl())
            } else if item.kind == TopLevelKind::Stmt {
                var unsafe *st = item.as_stmt()
                if (st != &null) && isa<Statements::DeclStmt>(st) {
                    out->push_back(cast<Statements::DeclStmt>(st)->decl)
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

    /// Members reachable through a value of type \p t: its record's own, then
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
        self.items_of_record_(d, depth)
    }

    /// What record, enum, interface or module \p d declares itself, in the
    /// order it is offered: what `.` and `::` can name before its bases and
    /// its extensions. The one list for a completion's items and for the
    /// file's declaration table (Tables.k), so the two cannot differ.
    fn own_members_(self, d: unsafe *Decl, out: *[unsafe *Decl]) {
        // A type keeps its members in typed lists; its DeclContext holds
        // what is nested in it. Both are what `.` and `::` can name.
        if isa<Declarations::ClassDecl>(d) {
            var unsafe *c = cast<Declarations::ClassDecl>(d)
            for var i: usize = 0; i < c->fields.size(); ++i {
                out->push_back(unsafe (c->fields[i] as unsafe *Decl))
            }

            for var i: usize = 0; i < c->methods.size(); ++i {
                out->push_back(unsafe (c->methods[i] as unsafe *Decl))
            }
        } else if isa<Declarations::StructDecl>(d) {
            var unsafe *c = cast<Declarations::StructDecl>(d)
            for var i: usize = 0; i < c->fields.size(); ++i {
                out->push_back(unsafe (c->fields[i] as unsafe *Decl))
            }

            for var i: usize = 0; i < c->methods.size(); ++i {
                out->push_back(unsafe (c->methods[i] as unsafe *Decl))
            }
        } else if isa<Declarations::UnionDecl>(d) {
            var unsafe *c = cast<Declarations::UnionDecl>(d)
            for var i: usize = 0; i < c->fields.size(); ++i {
                out->push_back(unsafe (c->fields[i] as unsafe *Decl))
            }

            for var i: usize = 0; i < c->methods.size(); ++i {
                out->push_back(unsafe (c->methods[i] as unsafe *Decl))
            }
        } else if isa<Declarations::EnumDecl>(d) {
            var unsafe *c = cast<Declarations::EnumDecl>(d)
            for var i: usize = 0; i < c->variants.size(); ++i {
                out->push_back(unsafe (c->variants[i] as unsafe *Decl))
            }
        } else if isa<Declarations::InterfaceDecl>(d) {
            var unsafe *c = cast<Declarations::InterfaceDecl>(d)
            for var i: usize = 0; i < c->methods.size(); ++i {
                out->push_back(unsafe (c->methods[i] as unsafe *Decl))
            }
        }

        var unsafe *dc = self.context_of_decl_(d)
        if dc != &null {
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                out->push_back(*dc->dc_decls.get(i))
            }
        }
    }

    /// The methods of the `extend` blocks of \p d that this file sees
    /// (MemberLookup's index, which applies the extension-visibility rule).
    fn items_of_extensions_(self, d: unsafe *Decl, depth: u32) {
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
                for var m: usize = 0; m < e->methods.size(); ++m {
                    self.item_(unsafe (e->methods[m] as unsafe *Decl), depth)
                }
            }
        }
    }

    fn items_of_record_(self, d: unsafe *Decl, depth: u32) {
        if (d == &null) || (depth > 8) {
            return
        }

        if isa<Declarations::ModuleDecl>(d) {
            // A file IS a module: `import std::io` binds `io` to io.k's
            // module_self, and what the file declares lives in its TU.
            var unsafe *mctx = NameLookup::ctx_of(d)
            if (mctx != &null) && (mctx->tu != &null) && (unsafe (mctx->tu->module_self as unsafe *Decl) == d) {
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
            self.items_of_extensions_(d, depth)
        }

        if isa<Declarations::ClassDecl>(d) {
            var unsafe *c = cast<Declarations::ClassDecl>(d)
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                self.items_of_type_(c->derives_list[i].base, depth + 1)
            }
        }
    }

    /// The cursor is after `recv.` / `recv->` / `recv::`.
    fn complete_member_(self, recv_type: unsafe *Type, recv_decl: unsafe *Decl) {
        self.completed = true
        var ac = AccessCheck(self.sc)
        var ml = MemberLookup(self.sc)
        self.ac_         = unsafe &ac
        self.ac_through_ = recv_type
        self.ml_         = unsafe &ml
        self.members_of_receiver_(recv_type, recv_decl)
        self.ac_         = &null
        self.ac_through_ = &null
        self.ml_         = &null
    }

    fn members_of_receiver_(self, recv_type: unsafe *Type, recv_decl: unsafe *Decl) {
        // A name that IS a scope (a module, a type named for a static or a
        // variant) offers what it declares; a value offers its type's members.
        var unsafe *dc = self.context_of_decl_(recv_decl)
        if dc != &null {
            self.items_of_record_(recv_decl, 0)
            return
        }

        if recv_type != &null {
            self.items_of_type_(recv_type, 0)
            return
        }

        if recv_decl == &null {
            return
        }

        if isa<Declarations::VariableDecl>(recv_decl) {
            self.items_of_type_(cast<Declarations::VariableDecl>(recv_decl)->type_, 0)
        } else if isa<Declarations::ParamDecl>(recv_decl) {
            self.items_of_type_(cast<Declarations::ParamDecl>(recv_decl)->type_, 0)
        } else if isa<Declarations::FieldDecl>(recv_decl) {
            self.items_of_type_(cast<Declarations::FieldDecl>(recv_decl)->type_, 0)
        }
    }

    /// The cursor (the marker, at byte \p at of the file) is on a bare
    /// name: locals, then the enclosing type, then the file, then what the
    /// file imports.
    fn complete_scope_(self, at: u32) {
        self.completed = true

        // The locals still in scope at the marker: the walk has met every
        // local of the function so far, those of blocks that have closed
        // too. Which blocks are open is read off the text, by the index
        // path's own test, so the two lists agree.
        var blocks: [Block]
        var fi: usize = 0
        if at != u32::MAX {
            var *ft = &self.files[self.file_(self.fid)]
            var cls = classify(ft->text)
            blocks = blocks_before(ft->text, cls, at as usize)
            fi = function_block(blocks)
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
                    self.items_of_record_(dc->dc_owner, 1)
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
