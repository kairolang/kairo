/// --- The Kairo Project ----------------------- Analyzer/Index/Inlays.k --- ///
///
///   Parameter-name inlay hints.
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
import Index::Bases::*
import Index::CompletionItems::*
import Index::Hovers::*
import Index::Indexer::*
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
    /// The start of the literal that begins at byte `off`, prefix included.
    /// A text literal's token (and so the expression's range) starts at its
    /// opening quote; the prefix (`f`, `r`, `b`, two of them) is a token of
    /// its own, touching the quote, that only the bytes show.
    fn with_text_prefix_(self, off: u32) -> u32 {
        if self.files.size() == 0 {
            return off
        }

        var *text = &self.files[0].text
        if ((off as usize) >= text->size())
            || (((text->data()[off as usize]) != ('"' as u8))
                && ((text->data()[off as usize]) != ('\'' as u8))) {
            return off
        }

        // A prefix is a whole word of one or two letters: a longer run
        // touching the quote is not one.
        var at = off as usize
        while (at > 0) && ((off as usize) - at < 3) {
            var c = text->data()[at - 1]
            var is_word = ((c >= ('a' as u8)) && (c <= ('z' as u8)))
                || ((c >= ('A' as u8)) && (c <= ('Z' as u8)))
                || ((c >= ('0' as u8)) && (c <= ('9' as u8)))
                || (c == ('_' as u8))
            if !is_word {
                break
            }

            at -= 1
        }

        var n = (off as usize) - at
        if (n == 0) || (n > 2) {
            return off
        }

        // `b` prefixes a string only: before `'` it is a name.
        var quote_is_char = text->data()[off as usize] == ('\'' as u8)
        for var i: usize = at; i < (off as usize); ++i {
            var c = text->data()[i] | (0x20 as u8)
            if (c != ('f' as u8)) && (c != ('r' as u8)) && (c != ('b' as u8)) {
                return off
            }

            if quote_is_char && (c == ('b' as u8)) {
                return off
            }

            // Two letters are two different prefixes.
            if (n == 2)
                && ((text->data()[at] | (0x20 as u8)) == (text->data()[at + 1] | (0x20 as u8))) {
                return off
            }
        }

        return at as u32
    }

    /// `name:` before each argument of a call to `d`, as an editor shows a
    /// parameter hint. Not where it would say nothing: an argument that is
    /// already named, or is a variable called what the parameter is.
    fn param_hints_(self, c: unsafe *Expressions::CallExpr, d: unsafe *Decl) {
        if (d == &null) || (!isa<Declarations::FunctionDecl>(d)) {
            return
        }

        var unsafe *f = cast<Declarations::FunctionDecl>(d)
        if f->is_operator {
            return
        }

        var unsafe *ctx = NameLookup::ctx_of(d)
        if ctx == &null {
            return
        }

        // The receiver is not an argument the caller writes in the list.
        var skip: usize = 0
        if (f->params.size() > 0) && f->params[0]->is_self {
            skip = 1
        }

        for var i: usize = 0; i < c->args.size(); ++i {
            var unsafe *arg = c->args[i]
            if (arg == &null) || isa<Expressions::NamedArgExpr>(arg) {
                continue
            }

            var pi = i + skip
            if pi >= f->params.size() {
                break
            }

            var unsafe *p = f->params[pi]
            if p->unname || p->is_pack || (!p->name.range.start.is_valid()) {
                continue
            }

            var pn = ctx->get_spelling(p->name)
            if pn.is_empty() || pn.starts_with("$") || pn.starts_with("_") {
                continue
            }

            if isa<NamedIdentExpr>(arg)
                && (self.ast_()->get_spelling(cast<NamedIdentExpr>(arg)->name) == pn) {
                continue
            }

            var off = self.own_off_(arg->range.start)
            if off == u32::MAX {
                continue
            }

            off = self.with_text_prefix_(off)

            var row = InlayRow{}
            row.off       = off
            row.label     = pn + ":"
            row.kind      = IHK_PARAMETER as u32
            row.pad_right = true
            self.inlays.push(row)
        }
    }
}
