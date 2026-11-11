/// --- The Kairo Project ------------------------ Analyzer/Index/Bases.k --- ///
///
///   Type hierarchy rows: bases, implementations and overriding methods.
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
import Index::CompletionItems::*
import Index::Hovers::*
import Index::Indexer::*
import Index::Inlays::*
import Index::Legend::*
import Index::Macros::*
import Index::Refs::*
import Index::Tokens::*
import Index::Writer::*

extend IndexWalker {
    /// The declaration a written type names: a path's last segment, or the
    /// record behind a canonical type.
    fn decl_of_type_(self, t: unsafe *Type) -> unsafe *Decl {
        if t == &null {
            return &null
        }

        if isa<Types::ChainType>(t) {
            var unsafe *c = cast<Types::ChainType>(t)
            if c->segments.size() > 0 {
                var unsafe *last = c->segments.get(c->segments.size() - 1)
                if last->resolved_decl != &null {
                    return last->resolved_decl
                }
            }
        }

        return self.type_decl_(t, 0)
    }

    fn base_edge_(self, d: unsafe *Decl, base: unsafe *Type, inherited: *[unsafe *Decl]) {
        var unsafe *bd = self.decl_of_type_(base)
        if bd == &null {
            return
        }

        inherited->push_back(bd)

        var name = self.ast_()->unwrap_token(decl_name_tok(d))
        var off  = self.own_off_(name.range.start)
        var bn   = decl_name_tok(bd).range
        if (off == u32::MAX) || (!bn.start.is_valid()) {
            return
        }

        var res = self.sm->resolve(bn.start)
        var row = BaseRow{}
        row.off      = off
        row.len      = name.range.size() as u32
        row.base_fid = res.fid as u32
        row.base_off = res.offset as u32
        row.base_len = bn.size() as u32
        row.name      = sema_dump_decl_name(self.ast_(), d)
        row.base_name = sema_dump_decl_name(self.ast_(), bd)
        row.kind      = self.symbol_kind_(d)
        row.base_kind = self.symbol_kind_(bd)
        self.bases.push_back(row)
    }

    /// Every requirement an interface gets from the interfaces it derives,
    /// nearest first, each once.
    fn inherited_methods_(self,
                               d:     unsafe *Decl,
                               depth: u32,
                               out:   *[string]) {
        if (d == &null) || (depth > 8) || (!isa<Declarations::InterfaceDecl>(d)) {
            return
        }

        var unsafe *it = cast<Declarations::InterfaceDecl>(d)
        if depth > 0 {
            for var i: usize = 0; i < it->methods.size(); ++i {
                var sig = self.signature_(unsafe (it->methods[i] as unsafe *Decl))
                var dup = false
                for var k: usize = 0; k < out->size(); ++k {
                    if (*out)[k] == sig {
                        dup = true
                    }
                }

                if !dup {
                    out->push_back(sig)
                }
            }
        }

        for var i: usize = 0; i < it->derives_list.size(); ++i {
            self.inherited_methods_(self.decl_of_type_(it->derives_list[i].base), depth + 1, out)
        }
    }

    /// The methods a type declares, whatever kind of type it is.
    fn methods_of_(self, d: unsafe *Decl, out: *[unsafe *Decl]) {
        if d == &null {
            return
        }

        if isa<Declarations::ClassDecl>(d) {
            var unsafe *c = cast<Declarations::ClassDecl>(d)
            for var i: usize = 0; i < c->methods.size(); ++i {
                out->push_back(unsafe (c->methods[i] as unsafe *Decl))
            }
        } else if isa<Declarations::StructDecl>(d) {
            var unsafe *c = cast<Declarations::StructDecl>(d)
            for var i: usize = 0; i < c->methods.size(); ++i {
                out->push_back(unsafe (c->methods[i] as unsafe *Decl))
            }
        } else if isa<Declarations::InterfaceDecl>(d) {
            var unsafe *c = cast<Declarations::InterfaceDecl>(d)
            for var i: usize = 0; i < c->methods.size(); ++i {
                out->push_back(unsafe (c->methods[i] as unsafe *Decl))
            }
        }
    }

    /// A method that has the name of a method of one of its type's bases
    /// implements or overrides it: an edge from the one to the other, so "go
    /// to implementation" on the base method finds this one. By name, not by
    /// signature: an overload set in the base maps to every method of that
    /// name, which errs toward showing one too many rather than missing one.
    fn method_edges_(self, d: unsafe *Decl, inherited: *[unsafe *Decl]) {
        var mine: [unsafe *Decl]
        self.methods_of_(d, &mine)
        if mine.empty() {
            return
        }

        for var b: usize = 0; b < inherited->size(); ++b {
            var theirs: [unsafe *Decl]
            self.methods_of_((*inherited)[b], &theirs)
            for var i: usize = 0; i < mine.size(); ++i {
                if mine[i]->is_implicit {
                    continue
                }

                var mn = sema_dump_decl_name(self.ast_(), mine[i])
                for var k: usize = 0; k < theirs.size(); ++k {
                    if sema_dump_decl_name(self.ast_(), theirs[k]) != mn {
                        continue
                    }

                    var at = decl_name_tok(mine[i]).range
                    var bn = decl_name_tok(theirs[k]).range
                    if cast<Declarations::FunctionDecl>(mine[i])->is_operator
                        && (cast<Declarations::FunctionDecl>(mine[i])->op_token.size() > 0) {
                        at = cast<Declarations::FunctionDecl>(mine[i])->op_token[0].range
                    }

                    if cast<Declarations::FunctionDecl>(theirs[k])->is_operator
                        && (cast<Declarations::FunctionDecl>(theirs[k])->op_token.size() > 0) {
                        bn = cast<Declarations::FunctionDecl>(theirs[k])->op_token[0].range
                    }

                    var off = self.own_off_(at.start)
                    if (off == u32::MAX) || (!bn.start.is_valid()) {
                        continue
                    }

                    var res = self.sm->resolve(bn.start)
                    var row = BaseRow{}
                    row.off       = off
                    row.len       = at.size() as u32
                    row.base_fid  = res.fid as u32
                    row.base_off  = res.offset as u32
                    row.base_len  = bn.size() as u32
                    row.name      = mn
                    row.base_name = mn
                    row.kind      = 6
                    row.base_kind = 6
                    self.bases.push_back(row)
                }
            }
        }
    }

    /// Records \p d's base edges and, for an interface that derives others,
    /// the inlay hint that spells out what it inherits.
    fn bases_of_(self, d: unsafe *Decl) {
        var inherited: [unsafe *Decl]
        if isa<Declarations::ClassDecl>(d) {
            var unsafe *c = cast<Declarations::ClassDecl>(d)
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                self.base_edge_(d, c->derives_list[i].base, &inherited)
            }

            for var i: usize = 0; i < c->implements.size(); ++i {
                self.base_edge_(d, c->implements[i].base, &inherited)
            }

            self.method_edges_(d, &inherited)
        } else if isa<Declarations::StructDecl>(d) {
            var unsafe *c = cast<Declarations::StructDecl>(d)
            for var i: usize = 0; i < c->implements.size(); ++i {
                self.base_edge_(d, c->implements[i].base, &inherited)
            }

            self.method_edges_(d, &inherited)
        } else if isa<Declarations::InterfaceDecl>(d) {
            var unsafe *c = cast<Declarations::InterfaceDecl>(d)
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                self.base_edge_(d, c->derives_list[i].base, &inherited)
            }

            self.method_edges_(d, &inherited)
            if c->derives_list.size() == 0 {
                return
            }

            // `interface math derives Sub + Add { }` reads as empty and is
            // not: show what it requires, inside its braces. One line (an
            // inlay hint cannot break lines), requirements separated by `;`.
            var sigs: [string]
            self.inherited_methods_(d, 0, &sigs)

            // Not the ones it restates itself.
            var label: string = ""
            for var i: usize = 0; i < sigs.size(); ++i {
                var own = false
                for var k: usize = 0; k < c->methods.size(); ++k {
                    if self.signature_(unsafe (c->methods[k] as unsafe *Decl)) == sigs[i] {
                        own = true
                    }
                }

                if own {
                    continue
                }

                if !label.empty() {
                    label += "; "
                }

                label += sigs[i]
            }

            if label.empty() {
                return
            }

            var name = self.ast_()->unwrap_token(c->name)
            var from = self.own_off_(name.range.end)
            if from == u32::MAX {
                return
            }

            var *text = &self.files[0].text
            var p = from as usize
            while (p < text->size()) && ((*text)[p] != 123) && ((*text)[p] != 59) {
                p += 1
            }

            if (p >= text->size()) || ((*text)[p] != 123) {
                return
            }

            var row = InlayRow{}
            row.off       = (p + 1) as u32
            row.label     = label
            row.kind      = 0
            row.pad_left  = true
            row.pad_right = true
            self.inlays.push_back(row)
        }
    }
}
