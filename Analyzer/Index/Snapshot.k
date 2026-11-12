/// --- The Kairo Project --------------------- Analyzer/Index/Snapshot.k --- ///
///
///   The snapshot's rows: what each row holds and the column each field is written at, for the writer and the server's reader alike.
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
import Protocol::*
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

/// One classified span, in bytes of the indexed file.
pub struct SemTok {
    var off:  u32 = 0
    var len:  u32 = 0
    var kind: u32 = 0
    var mods: u32 = 0
}

/// One name -> declaration edge. `def_*` name the declaration's name token.
pub struct RefRow {
    var off:      u32  = 0
    var len:      u32  = 0
    var def_fid:  u32  = u32::MAX
    var def_off:  u32  = 0
    var def_len:  u32  = 0
    var hover:    u32  = u32::MAX
    var is_decl:  bool = false

    /// The declaration of the name's TYPE (a variable's class, a function's
    /// result), for "go to type definition". u32::MAX when it has none.
    var type_fid: u32 = u32::MAX
    var type_off: u32 = 0
    var type_len: u32 = 0

    /// What the name refers to (a TT_ value): call hierarchy needs to tell a
    /// call from any other use.
    var kind: u32 = 255
}

/// An import path and the file it resolved to.
pub struct LinkRow {
    var off:    u32    = 0
    var len:    u32    = 0
    var target: string = ""
}

pub struct SymRow {
    var name:    string = ""
    var detail:  string = ""
    var kind:    u32    = 0   ///< LSP SymbolKind
    var start:   u32    = 0   ///< whole declaration, bytes
    var end:     u32    = 0
    var sel_off: u32    = 0   ///< name token
    var sel_len: u32    = 0
}

pub struct InlayRow {
    var off:       u32    = 0
    var label:     string = ""
    var kind:      u32    = IHK_TYPE as u32  ///< LSP InlayHintKind; 0 leaves it out
    var pad_left:  bool   = false
    var pad_right: bool   = false
}

/// "This type derives or implements that one": the edge implementation and
/// type-hierarchy requests walk, in either direction.
pub struct BaseRow {
    var off:      u32 = 0         ///< the deriving declaration's name
    var len:      u32 = 0
    var base_fid: u32 = u32::MAX
    var base_off: u32 = 0
    var base_len: u32 = 0
    var name:      string = ""    ///< the deriving declaration
    var base_name: string = ""
    var kind:      u32    = SYM_CLASS as u32  ///< LSP SymbolKind of the deriving declaration
    var base_kind: u32    = SYM_CLASS as u32
}

pub struct ItemRow {
    var label:  string = ""
    var detail: string = ""
    var kind:   u32    = 0  ///< LSP CompletionItemKind
    var sort:   u32    = 0  ///< smaller sorts first
    var doc:    string = "" ///< the `///` block; sent on completionItem/resolve
}

/// A file some row points into: its text, for turning bytes into positions.
pub class FileText {
    pub var fid:   u32     = u32::MAX
    pub var path:  string  = ""
    pub var text:  string  = ""
    pub var lines: LineMap

    fn FileText(self) = default
}

/// The identifier a completion request plants where the cursor is. It parses
/// as a name anywhere a name can go, so the tree keeps the node the cursor is
/// in, and Sema leaves that one node unresolved. The walk then finds it by
/// spelling and reads the scope around it.
pub fn completion_marker() -> string {
    return "kalsCompletionMarker"
}

// --- members ---------------------------------------------------------------
//
// The snapshot is the JSON a worker writes and the server reads (Worker.k,
// LiveWorker.k, Writer.k, Macros.k, Tokens.k write it; Server/ reads it).
// Its own members are named here, once, for both sides. A row that IS an
// LSP object (an outline symbol, an inlay hint, a completion item, a
// diagnostic, a fix's edit) uses the LSP names (Protocol.k K_*), since the
// server forwards it as it is.

// the document
pub const SK_OK:          string = "ok"          ///< false: `error` says why, nothing else is written
pub const SK_ERROR:       string = "error"
pub const SK_FILES:       string = "files"       ///< the indexed files' nodes; in a node, the paths its rows index
pub const SK_UNCHECKED:   string = "unchecked"   ///< files syntax errors left unchecked
pub const SK_PARTIAL:     string = "partial"     ///< files checked without the bodies the errors are in
pub const SK_WIDE:        string = "wide"        ///< every file indexed; false over WIDE_INDEX_LIMIT (the open buffers only)
pub const SK_HEADER:      string = "header"      ///< `--as-module` (the header job): the module's header, relative
pub const SK_ERRORS:      string = "errors"      ///< `--as-module`: the run's error count
pub const SK_CXX_FLAGS:   string = "cxx_flags"
pub const SK_C_FLAGS:     string = "c_flags"
pub const SK_DIAGNOSTICS: string = "diagnostics" ///< diagnostic rows
pub const SK_DEPS:        string = "deps"        ///< every file of the graph
pub const SK_PARSED:      string = "parsed"      ///< syntax-only: the buffer parsed without error
pub const SK_TIMING:      string = "timing"      ///< the worker's own timings, for the trace
pub const SK_RUN_US:      string = "run_us"
pub const SK_WALK_US:     string = "walk_us"
pub const SK_WRITE_US:    string = "write_us"
pub const SK_ASSEMBLE_US: string = "assemble_us"
pub const SK_UNIT_FIDS:   string = "unit_fids"

// a file node (Writer.k)
pub const SK_PATH:    string = "path"
pub const SK_TOKENS:  string = "tokens"   ///< semantic tokens, LSP-encoded
pub const SK_REFS:    string = "refs"     ///< REF_* rows
pub const SK_BASES:   string = "bases"    ///< BASE_* rows
pub const SK_LINKS:   string = "links"    ///< LINK_* rows
pub const SK_MACROS:  string = "macros"   ///< MACRO_* rows
pub const SK_HOVERS:  string = "hovers"   ///< hover texts, by a ref row's REF_HOVER
pub const SK_SYMBOLS: string = "symbols"  ///< outline symbols, flat, in source order
pub const SK_INLAYS:  string = "inlays"   ///< inlay hints
pub const SK_ITEMS:   string = "items"    ///< completion items (a completion run only)
pub const SK_DOC:     string = "doc"      ///< a completion item's `///` block

// a diagnostic row: the file, the LSP diagnostic, the fixes; a fix is a
// title and its edits, each edit a path, a range and the new text
pub const SK_DIAG:  string = "diag"
pub const SK_FIXES: string = "fixes"
pub const SK_EDITS: string = "edits"

// --- row columns -----------------------------------------------------------
//
// Rows are JSON arrays, written positionally by Writer.k (Macros.k for the
// macro rows) and read by index on the server (Server/Lookup.k nth()). These
// constants are the one statement of the order: a column added to a writer
// is added here, and every reader names it.

/// A "refs" row (RefRow): the name's range; where it is declared (file index, -1 for none); the hover index (-1: none); 1 on the declaration itself; where its TYPE is declared; its TT_ kind.
pub const REF_LINE:      i64 = 0
pub const REF_CHAR:      i64 = 1
pub const REF_LEN:       i64 = 2
pub const REF_DEF_FILE:  i64 = 3
pub const REF_DEF_LINE:  i64 = 4
pub const REF_DEF_CHAR:  i64 = 5
pub const REF_DEF_LEN:   i64 = 6
pub const REF_HOVER:     i64 = 7
pub const REF_IS_DECL:   i64 = 8
pub const REF_TYPE_FILE: i64 = 9
pub const REF_TYPE_LINE: i64 = 10
pub const REF_TYPE_CHAR: i64 = 11
pub const REF_TYPE_LEN:  i64 = 12
pub const REF_KIND:      i64 = 13

/// A "bases" row (BaseRow): the derived name's range, the base's declaration, both names and both kinds.
pub const BASE_LINE:      i64 = 0
pub const BASE_CHAR:      i64 = 1
pub const BASE_LEN:       i64 = 2
pub const BASE_BASE_FILE: i64 = 3
pub const BASE_BASE_LINE: i64 = 4
pub const BASE_BASE_CHAR: i64 = 5
pub const BASE_BASE_LEN:  i64 = 6
pub const BASE_NAME:      i64 = 7
pub const BASE_BASE_NAME: i64 = 8
pub const BASE_KIND:      i64 = 9
pub const BASE_BASE_KIND: i64 = 10

/// A "links" row (LinkRow): the import path's range and the file it names.
pub const LINK_LINE:   i64 = 0
pub const LINK_CHAR:   i64 = 1
pub const LINK_LEN:    i64 = 2
pub const LINK_TARGET: i64 = 3

/// A "macros" row: the invocation's start and first-line length, its expansion, and where it ends.
pub const MACRO_LINE:     i64 = 0
pub const MACRO_CHAR:     i64 = 1
pub const MACRO_LEN:      i64 = 2
pub const MACRO_TEXT:     i64 = 3
pub const MACRO_END_LINE: i64 = 4
pub const MACRO_END_CHAR: i64 = 5
