/// --- The Kairo Project ----------------------- Analyzer/Index/Writer.k --- ///
///
///   Writes the snapshot: every table of rows, in the column order Snapshot.k names.
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
import Index::Inlays::*
import Index::Legend::*
import Index::Macros::*
import Index::Refs::*
import Index::Snapshot::*
import Index::Tables::*
import Index::Tokens::*
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
    /// UTF-16 length of bytes [off, off+len) of file \p fi.
    fn len16_(self, fi: usize, off: usize, len: usize) -> usize {
        var units: usize = 0
        var i            = off
        var end          = off + len
        var *text        = &self.files[fi].text
        if end > text->size() {
            end = text->size()
        }

        while i < end {
            var c = (*text)[i]
            if c >= 0xF0 {
                i += 4
                units += 2
            } else if c >= 0xE0 {
                i += 3
                units += 1
            } else if c >= 0xC0 {
                i += 2
                units += 1
            } else {
                i += 1
                units += 1
            }
        }

        return units
    }

    /// Writes the Position of byte \p off of file \p fi.
    fn pos_(self, w: *JsonWriter, fi: usize, off: usize) {
        var line = self.files[fi].lines.line_of(off) as i64
        write_lsp_position(
            w,
            line,
            self.files[fi].lines.character(self.files[fi].text, off, false) as i64,
        )
    }

    /// Writes the Range of \p len bytes at \p off of file \p fi.
    fn range_(self, w: *JsonWriter, fi: usize, off: usize, len: usize) {
        var *lm = &self.files[fi].lines
        var *tx = &self.files[fi].text
        write_lsp_range(
            w,
            lm->line_of(off) as i64,
            lm->character(*tx, off, false) as i64,
            lm->line_of(off + len) as i64,
            lm->character(*tx, off + len, false) as i64,
        )
    }

    /// Writes this file's index as one JSON object into \p w.
    pub fn write(self, w: *JsonWriter) {
        w->begin_object()
        w->field(SK_PATH, self.files[0].path)

        // --- semantic tokens: LSP's relative encoding, five integers each.
        var all: [SemTok]
        self.lexical_(&all)

        encode_tokens(&all, &self.files[0], w)

        // --- refs: [line, char, len, declFile, declLine, declChar, declLen, hover, isDecl,
        //            typeFile, typeLine, typeChar, typeLen, kind]
        // Sorted by position (stable: offset, then walk order), so the server
        // finds the row under the cursor by binary search.
        var order: [u64]
        order.reserve(self.refs.size())
        for var i: usize = 0; i < self.refs.size(); ++i {
            order.push_back(((self.refs[i].off as u64) << 32) | (i as u64))
        }

        sort_u64(&order)

        // --- refs: the REF_* columns of Snapshot.k, in that order
        w->key(SK_REFS)
        w->begin_array()
        for var oi: usize = 0; oi < order.size(); ++oi {
            var r = self.refs[(order[oi] & 0xFFFFFFFF) as usize]
            w->begin_array()
            var line = self.files[0].lines.line_of(r.off as usize)
            w->uint(line)
            w->uint(
                self.files[0].lines.character(
                    self.files[0].text,
                    r.off as usize,
                    false,
                ),
            )

            w->uint(self.len16_(0, r.off as usize, r.len as usize))
            if r.def_fid == u32::MAX {
                w->integer(-1)
                w->uint(0)
                w->uint(0)
                w->uint(0)
            } else {
                var fi = self.file_(r.def_fid)
                w->uint(fi)
                w->uint(self.files[fi].lines.line_of(r.def_off as usize))
                w->uint(
                    self.files[fi].lines.character(
                        self.files[fi].text,
                        r.def_off as usize,
                        false,
                    ),
                )

                w->uint(self.len16_(fi, r.def_off as usize, r.def_len as usize))
            }

            if r.hover == u32::MAX {
                w->integer(-1)
            } else {
                w->uint(r.hover as usize)
            }

            var decl_flag: usize = 0
            if r.is_decl {
                decl_flag = 1
            }

            w->uint(decl_flag)
            if r.type_fid == u32::MAX {
                w->integer(-1)
                w->uint(0)
                w->uint(0)
                w->uint(0)
            } else {
                var ti = self.file_(r.type_fid)
                w->uint(ti)
                w->uint(self.files[ti].lines.line_of(r.type_off as usize))
                w->uint(
                    self.files[ti].lines.character(
                        self.files[ti].text,
                        r.type_off as usize,
                        false,
                    ),
                )

                w->uint(
                    self.len16_(ti, r.type_off as usize, r.type_len as usize),
                )
            }

            w->uint(r.kind as usize)
            w->end_array()
        }

        w->end_array()

        // --- bases: [line, char, len, baseFile, baseLine, baseChar, baseLen, name, baseName, kind, baseKind]
        w->key(SK_BASES)
        w->begin_array()
        for var i: usize = 0; i < self.bases.size(); ++i {
            var b  = self.bases[i]
            var bi = self.file_(b.base_fid)
            w->begin_array()
            w->uint(self.files[0].lines.line_of(b.off as usize))
            w->uint(
                self.files[0].lines.character(
                    self.files[0].text,
                    b.off as usize,
                    false,
                ),
            )

            w->uint(self.len16_(0, b.off as usize, b.len as usize))
            w->uint(bi)
            w->uint(self.files[bi].lines.line_of(b.base_off as usize))
            w->uint(
                self.files[bi].lines.character(
                    self.files[bi].text,
                    b.base_off as usize,
                    false,
                ),
            )

            w->uint(self.len16_(bi, b.base_off as usize, b.base_len as usize))
            w->str(b.name)
            w->str(b.base_name)
            w->uint(b.kind as usize)
            w->uint(b.base_kind as usize)
            w->end_array()
        }

        w->end_array()

        // --- links: [line, char, len, target path]
        w->key(SK_LINKS)
        w->begin_array()
        for var i: usize = 0; i < self.links.size(); ++i {
            w->begin_array()
            w->uint(self.files[0].lines.line_of(self.links[i].off as usize))
            w->uint(
                self.files[0].lines.character(
                    self.files[0].text,
                    self.links[i].off as usize,
                    false,
                ),
            )

            w->uint(
                self.len16_(
                    0,
                    self.links[i].off as usize,
                    self.links[i].len as usize,
                ),
            )

            w->str(self.links[i].target)
            w->end_array()
        }

        w->end_array()

        self.macros_(w)

        w->key(SK_FILES)
        w->begin_array()
        for var i: usize = 0; i < self.files.size(); ++i {
            w->str(self.files[i].path)
        }

        w->end_array()

        w->key(SK_HOVERS)
        w->begin_array()
        for var i: usize = 0; i < self.hovers.size(); ++i {
            w->str(self.hovers[i])
        }

        w->end_array()

        // --- outline: flat, in source order; the server nests by range.
        w->key(SK_SYMBOLS)
        w->begin_array()
        for var i: usize = 0; i < self.syms.size(); ++i {
            var s = self.syms[i]
            w->begin_object()
            w->field(K_NAME, s.name)
            if !s.detail.empty() {
                w->field(K_DETAIL, s.detail)
            }

            w->field_uint(K_KIND, s.kind as usize)
            w->key(K_RANGE)
            self.range_(w, 0, s.start as usize, (s.end - s.start) as usize)
            w->key(K_SELECTION_RANGE)
            self.range_(w, 0, s.sel_off as usize, s.sel_len as usize)
            w->end_object()
        }

        w->end_array()

        w->key(SK_INLAYS)
        w->begin_array()
        for var i: usize = 0; i < self.inlays.size(); ++i {
            w->begin_object()
            w->key(K_POSITION)
            self.pos_(w, 0, self.inlays[i].off as usize)
            w->field(K_LABEL, self.inlays[i].label)
            if self.inlays[i].kind != 0 {
                w->field_uint(K_KIND, self.inlays[i].kind as usize)
            }

            if self.inlays[i].pad_left {
                w->field_bool(K_PADDING_LEFT, true)
            }

            if self.inlays[i].pad_right {
                w->field_bool(K_PADDING_RIGHT, true)
            }

            w->end_object()
        }

        w->end_array()

        self.write_scope_(w)

        if self.completed {
            w->key(SK_ITEMS)
            w->begin_array()
            for var i: usize = 0; i < self.items.size(); ++i {
                var it = self.items[i]
                w->begin_object()
                w->field(K_LABEL, it.label)
                w->field_uint(K_KIND, it.kind as usize)
                if !it.detail.empty() {
                    w->field(K_DETAIL, it.detail)
                }

                // sortText orders groups (locals before members before
                // imports); within a group the editor sorts by label.
                w->field(K_SORT_TEXT, f"{it.sort}{it.label}")
                if !it.doc.empty() {
                    w->field(SK_DOC, it.doc)
                }

                w->end_object()
            }

            w->end_array()
        }

        w->end_object()
    }
}
