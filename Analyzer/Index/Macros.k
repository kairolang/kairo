/// --- The Kairo Project ----------------------- Analyzer/Index/Macros.k --- ///
///
///   Macro rows: expansions for hover and the expand-macro action.
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
import Index::Hovers::*
import Index::Indexer::*
import Index::Inlays::*
import Index::Legend::*
import Index::Refs::*
import Index::Tokens::*
import Index::Writer::*

extend IndexWalker {
    /// Spacing for a spelled-back expansion: none inside `a.b`, `a::b`,
    /// `f(x)`, `v[i]`, before `,` and `;`; one space elsewhere. The lexer
    /// keeps no inter-token whitespace, so this is a reading aid, as
    /// `--dump-preprocessed` is (which puts one space everywhere).
    fn glue_(self, const prev: string, const cur: string) -> bool {
        if prev.empty() {
            return true
        }

        if (cur == ")") || (cur == "]") || (cur == ",") || (cur == ";") || (cur == ".") || (cur == "::")
            || (cur == "?.") {
            return true
        }

        if (prev == "(") || (prev == "[") || (prev == ".") || (prev == "::") || (prev == "?.") {
            return true
        }

        if (cur == "(") || (cur == "[") {
            // a call or an index: after a name or a closing bracket
            var c = prev[prev.size() - 1]
            return ((c >= ('a' as u8)) && (c <= ('z' as u8))) || ((c >= ('A' as u8)) && (c <= ('Z' as u8))) || ((c >= ('0' as u8)) && (c <= ('9' as u8)))
                || (c == ('_' as u8)) || (c == (')' as u8)) || (c == (']' as u8)) || (c == ('!' as u8))
        }

        return false
    }

    /// `macros`: one row per macro invocation in this file, the outermost
    /// only (a nested invocation's tokens are part of its parent's), as
    /// `[line, char, len, expansion, endLine, endChar]`. A token the
    /// preprocessor produced is TkMacroExpand and carries an invocation's
    /// range in this file: the outermost one's, or, for what an invocation
    /// in its ARGUMENTS produced, that inner invocation's, which lies inside
    /// it. So a run of such tokens whose ranges overlap is one invocation,
    /// spanning their union. The text is spelled through TokenText, as
    /// `--dump-preprocessed` spells it, with the body's own line breaks.
    fn macros_(self, w: *JsonWriter) {
        w->key(SK_MACROS)
        w->begin_array()
        if (self.ast_() == &null) || (self.ast_()->tcm == &null) {
            w->end_array()
            return
        }

        var unsafe *tcm = self.ast_()->tcm
        var unsafe *tb  = tcm->get_tokens(self.fid)
        if tb == &null {
            w->end_array()
            return
        }

        var *ft = &self.files[0]
        var i: usize = 0
        var n = tb->size()
        while i < n {
            var tok = *tb->get(i)
            if (tok.kind as u32) != (TokenKind::TkMacroExpand as u32) {
                i += 1
                continue
            }

            var off = self.own_off_(tok.range.start)
            var len = tok.range.size() as usize
            if (off == u32::MAX) || (((off as usize) + len) > ft->text.size()) {
                i += 1
                continue
            }

            var text:  string = ""
            var prev:  string = ""
            var depth: usize  = 0
            var fresh_line = true
            var gs = off as usize        // the group's range so far, in bytes
            var ge = gs + len
            var j = i
            while j < n {
                var t = *tb->get(j)
                if (t.kind as u32) != (TokenKind::TkMacroExpand as u32) {
                    break
                }

                var to = self.own_off_(t.range.start)
                if to == u32::MAX {
                    break
                }

                var ts = to as usize
                var te = ts + (t.range.size() as usize)
                if (te < gs) || (ts > ge) || ((j > i) && ((te == gs) || (ts == ge))) {
                    break // a separate invocation (touching is not overlapping)
                }

                if ts < gs {
                    gs = ts
                }

                if te > ge {
                    ge = te
                }

                j += 1
                var u = self.ast_()->unwrap_token(t)
                if (u.kind == TokenKind::TkWhitespace) || (u.kind == TokenKind::TkEof)
                    || (u.kind == TokenKind::TkFileStart) || (u.kind == TokenKind::TkFileEnd) {
                    continue
                }

                if u.kind == TokenKind::TkNewLine {
                    if !text.empty() {
                        fresh_line = true
                    }

                    continue
                }

                var sp = *TokenText::resolve(t, tcm).get_text()
                if (sp == "}") && (depth > 0) {
                    depth -= 1
                }

                if fresh_line && (!text.empty()) {
                    text += "\n"
                    for var d: usize = 0; d < depth; ++d {
                        text += "    "
                    }

                    prev = ""
                } else if !self.glue_(prev, sp) {
                    text += " "
                }

                fresh_line = false
                text += sp
                prev = sp
                if sp == "{" {
                    depth += 1
                }
            }

            i = j
            if text.empty() {
                continue
            }

            if ge > ft->text.size() {
                ge = ft->text.size()
            }

            var so   = gs
            var eo   = ge
            var line = ft->lines.line_of(so)
            var el   = ft->lines.line_of(eo)
            var row_len = utf16_len(&ft->text, so, eo - so)
            if el != line {
                row_len = utf16_len(&ft->text, so, ft->lines.line_end(ft->text, line) - so)
            }

            w->begin_array()
            w->uint(line)
            w->uint(ft->lines.character(ft->text, so, false))
            w->uint(row_len)
            w->str(text)
            w->uint(el)
            w->uint(ft->lines.character(ft->text, eo, false))
            w->end_array()
        }

        w->end_array()
    }
}
