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
        // offer from another file.
        if name.starts_with("_") || name.ends_with("_") {
            if NameLookup::ctx_of(d) != self.ast_() {
                return
            }
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

    /// Every name a file declares at its top level. The file's DeclContext
    /// lists its functions and types; a top-level `const` / `var` is only in
    /// the program's item list, so both are read.
    fn items_of_tu_(self, tu: unsafe *TranslationUnit, sort: u32) {
        if tu == &null {
            return
        }

        self.items_of_context_(unsafe (tu as unsafe *DeclContext), sort)
        if tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); i++ {
            var item = *items->get(i)
            if item.kind == TopLevelKind::Decl {
                self.item_(item.as_decl(), sort)
            }
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

    fn items_of_record_(self, d: unsafe *Decl, depth: u32) {
        if (d == &null) || (depth > 8) {
            return
        }

        // A type keeps its members in typed lists; its DeclContext holds
        // what is nested in it. Both are what `.` and `::` can name.
        if isa<Declarations::ClassDecl>(d) {
            var unsafe *c = cast<Declarations::ClassDecl>(d)
            for var i: usize = 0; i < c->fields.size(); ++i {
                self.item_(unsafe (c->fields[i] as unsafe *Decl), depth)
            }

            for var i: usize = 0; i < c->methods.size(); ++i {
                self.item_(unsafe (c->methods[i] as unsafe *Decl), depth)
            }
        } else if isa<Declarations::StructDecl>(d) {
            var unsafe *c = cast<Declarations::StructDecl>(d)
            for var i: usize = 0; i < c->fields.size(); ++i {
                self.item_(unsafe (c->fields[i] as unsafe *Decl), depth)
            }

            for var i: usize = 0; i < c->methods.size(); ++i {
                self.item_(unsafe (c->methods[i] as unsafe *Decl), depth)
            }
        } else if isa<Declarations::UnionDecl>(d) {
            var unsafe *c = cast<Declarations::UnionDecl>(d)
            for var i: usize = 0; i < c->fields.size(); ++i {
                self.item_(unsafe (c->fields[i] as unsafe *Decl), depth)
            }

            for var i: usize = 0; i < c->methods.size(); ++i {
                self.item_(unsafe (c->methods[i] as unsafe *Decl), depth)
            }
        } else if isa<Declarations::EnumDecl>(d) {
            var unsafe *c = cast<Declarations::EnumDecl>(d)
            for var i: usize = 0; i < c->variants.size(); ++i {
                self.item_(unsafe (c->variants[i] as unsafe *Decl), depth)
            }
        } else if isa<Declarations::InterfaceDecl>(d) {
            var unsafe *c = cast<Declarations::InterfaceDecl>(d)
            for var i: usize = 0; i < c->methods.size(); ++i {
                self.item_(unsafe (c->methods[i] as unsafe *Decl), depth)
            }
        } else if isa<Declarations::ModuleDecl>(d) {
            // A file IS a module: `import std::io` binds `io` to io.k's
            // module_self, and what the file declares lives in its TU.
            var unsafe *mctx = NameLookup::ctx_of(d)
            if (mctx != &null) && (mctx->tu != &null) && (unsafe (mctx->tu->module_self as unsafe *Decl) == d) {
                self.items_of_tu_(mctx->tu, depth)
            }
        }

        self.items_of_context_(self.context_of_decl_(d), depth)

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

    /// The cursor is on a bare name: locals, then the enclosing type, then
    /// the file, then what the file imports.
    fn complete_scope_(self) {
        self.completed = true

        var n = self.locals_.size()
        for var i: usize = 0; i < n; ++i {
            self.item_(self.locals_[n - 1 - i], 0)
        }

        if self.cur_fn_ != &null {
            var unsafe *fd = unsafe (self.cur_fn_ as unsafe *Decl)
            var unsafe *dc = fd->semantic_dc
            while dc != &null {
                if dc->is_type_scope() {
                    self.items_of_record_(dc->dc_owner, 1)
                }

                dc = dc->dc_parent
            }
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
            self.overlay_rows_(tu)
        }
    }
}
