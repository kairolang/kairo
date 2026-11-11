/// --- The Kairo Project --------------------- Analyzer/Index/Indexer.k --- ///
///
///   Turns one type-checked file into what an editor asks for.
///
///   Runs inside the compiler, at SemaPhase::Checked (Tooling/SemaObserver.k):
///   names and types are resolved and the tree is still the one the user
///   wrote. One walk produces, for one file:
///
///     tokens   semantic highlighting, already delta-encoded for LSP
///     refs     every name use and declaration -> where it is declared, with
///              the hover text; definition, hover, highlight, references and
///              rename all read this one table
///     symbols  the outline
///     inlays   the types of declarations that did not spell one
///     items    completion items, when the buffer carries a completion marker
///
///   EVERYTHING LEAVES IN LSP COORDINATES (0-based line, UTF-16 column). The
///   server never converts a position on the way out; it only looks rows up.
///
///   RANGES COME FROM NAME TOKENS, never from node ranges: a node's range is
///   not faithful to its text (P534), a name token's is.
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

// --- the legend -------------------------------------------------------------
//
// Index = position in the `tokenTypes` / `tokenModifiers` arrays the server
// advertises at initialize (Server.k writes them from token_type_names() and
// token_modifier_names(), so the two cannot drift apart).

pub fn TT_NAMESPACE()  -> u32 { return 0 }
pub fn TT_TYPE()       -> u32 { return 1 }
pub fn TT_CLASS()      -> u32 { return 2 }
pub fn TT_ENUM()       -> u32 { return 3 }
pub fn TT_INTERFACE()  -> u32 { return 4 }
pub fn TT_STRUCT()     -> u32 { return 5 }
pub fn TT_TYPE_PARAM() -> u32 { return 6 }
pub fn TT_PARAMETER()  -> u32 { return 7 }
pub fn TT_VARIABLE()   -> u32 { return 8 }
pub fn TT_PROPERTY()   -> u32 { return 9 }
pub fn TT_ENUM_MEMBER() -> u32 { return 10 }
pub fn TT_FUNCTION()   -> u32 { return 11 }
pub fn TT_METHOD()     -> u32 { return 12 }
pub fn TT_MACRO()      -> u32 { return 13 }
pub fn TT_KEYWORD()    -> u32 { return 14 }
pub fn TT_COMMENT()    -> u32 { return 15 }
pub fn TT_STRING()     -> u32 { return 16 }
pub fn TT_NUMBER()     -> u32 { return 17 }
pub fn TT_OPERATOR()   -> u32 { return 18 }
pub fn TT_SELF()       -> u32 { return 19 }
pub fn TT_BUILTIN()    -> u32 { return 20 }
pub fn TT_TYPE_ALIAS() -> u32 { return 21 }
pub fn TT_UNION()      -> u32 { return 22 }
pub fn TT_NONE()       -> u32 { return 255 }

pub fn token_type_names() -> string {
    return "[\"namespace\",\"type\",\"class\",\"enum\",\"interface\",\"struct\",\"typeParameter\",\"parameter\"," +
        "\"variable\",\"property\",\"enumMember\",\"function\",\"method\",\"macro\",\"keyword\",\"comment\"," +
        "\"string\",\"number\",\"operator\",\"selfKeyword\",\"builtinType\",\"typeAlias\",\"union\"]"
}

pub fn TM_DECLARATION() -> u32 { return 1 << 0 }
pub fn TM_DEFINITION()  -> u32 { return 1 << 1 }
pub fn TM_READONLY()    -> u32 { return 1 << 2 }
pub fn TM_STATIC()      -> u32 { return 1 << 3 }
pub fn TM_DEPRECATED()  -> u32 { return 1 << 4 }
pub fn TM_ABSTRACT()    -> u32 { return 1 << 5 }
pub fn TM_ASYNC()       -> u32 { return 1 << 6 }
pub fn TM_MODIFICATION() -> u32 { return 1 << 7 }
pub fn TM_DOCUMENTATION() -> u32 { return 1 << 8 }
pub fn TM_DEFAULT_LIB() -> u32 { return 1 << 9 }
/// The callee was picked from an overload set, or is a user `op`.
pub fn TM_OVERLOADED()  -> u32 { return 1 << 10 }
/// The callee dispatches at run time through `where` guards.
pub fn TM_DISPATCHED()  -> u32 { return 1 << 11 }
pub fn TM_UNSAFE()      -> u32 { return 1 << 12 }
/// Declared in C or C++ and reached through `ffi`.
pub fn TM_FFI()         -> u32 { return 1 << 13 }
pub fn TM_CONSTANT()    -> u32 { return 1 << 14 }
pub fn TM_CONSTRUCTOR() -> u32 { return 1 << 15 }
/// The callee is declared in an `extend` block, not in the type itself.
pub fn TM_EXTENSION()   -> u32 { return 1 << 16 }

pub fn token_modifier_names() -> string {
    return "[\"declaration\",\"definition\",\"readonly\",\"static\",\"deprecated\",\"abstract\",\"async\"," +
        "\"modification\",\"documentation\",\"defaultLibrary\",\"overloaded\",\"dispatched\",\"unsafe\"," +
        "\"ffi\",\"constant\",\"constructor\",\"extension\"]"
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
    var kind:      u32    = 1     ///< LSP InlayHintKind: 1 type, 2 parameter
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
    var kind:      u32    = 5     ///< LSP SymbolKind of the deriving declaration
    var base_kind: u32    = 5
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

/// UTF-16 length of bytes [off, off+len) of \p text.
pub fn utf16_len(text: *const string, off: usize, len: usize) -> usize {
    var units: usize = 0
    var i   = off
    var end = off + len
    if end > text->size() {
        end = text->size()
    }

    while i < end {
        var c = (*text)[i]
        if c >= 0xF0 {
            i     += 4
            units += 2
        } else if c >= 0xE0 {
            i     += 3
            units += 1
        } else if c >= 0xC0 {
            i     += 2
            units += 1
        } else {
            i     += 1
            units += 1
        }
    }

    return units
}

/// The token type the raw lex alone decides for \p t at [off, off+len) of
/// \p text: keywords, literals, comments, primitive type names. TT_NONE for
/// an identifier, which only the walk can classify.
pub fn lexical_kind(t: Token, text: *const string, off: u32, len: u32, mods: *u32) -> u32 {
    *mods = 0
    if t.kind == TokenKind::AtComment {
        if t.imm == 1 {
            *mods = TM_DOCUMENTATION()
        }

        return TT_COMMENT()
    }

    if (t.kind == TokenKind::LitString) || (t.kind == TokenKind::LitChar) {
        return TT_STRING()
    }

    if (t.kind == TokenKind::LitInt) || (t.kind == TokenKind::LitFloat) {
        return TT_NUMBER()
    }

    if t.kind == TokenKind::KwSelf {
        return TT_SELF()
    }

    if is_keyword(t.kind) || (t.kind == TokenKind::LitNull) {
        return TT_KEYWORD()
    }

    if t.kind == TokenKind::LitIdentifier {
        return TT_NONE() // left to the walk, or to the editor's grammar
    }

    if (len > 0) && ((off as usize) < text->size()) {
        // A word that is neither identifier nor keyword is a primitive type
        // name (`i32`, `bool`, `usize`).
        var c = (*text)[off as usize]
        if ((c >= 97) && (c <= 122)) || ((c >= 65) && (c <= 90)) || (c == 95) {
            *mods = TM_DEFAULT_LIB()
            return TT_BUILTIN()
        }
    }

    return TT_NONE()
}

/// Writes \p all (sorted, in bytes of \p f) as the `tokens` array: LSP's
/// relative five-integer encoding, one token per line of a multi-line one.
pub fn encode_tokens(all: *const [SemTok], f: *const FileText, w: *JsonWriter) {
    w->key("tokens")
    w->begin_array()
    var prev_line: usize = 0
    var prev_char: usize = 0
    var last_end:  usize = 0
    for var i: usize = 0; i < all->size(); ++i {
        var off = (*all)[i].off as usize
        var end = off + ((*all)[i].len as usize)
        if (off < last_end) || (end > f->text.size()) {
            continue // overlapping or out of range: the encoding cannot express it
        }

        last_end = end

        // A token may not span lines; a block comment or a multi-line
        // string becomes one token per line.
        var seg = off
        while seg < end {
            var line     = f->lines.line_of(seg)
            var line_end = f->lines.line_end(f->text, line)
            var stop     = end
            if stop > line_end {
                stop = line_end
            }

            if stop > seg {
                var ch = f->lines.character(f->text, seg, false)
                var dl = line - prev_line
                var dc = ch
                if dl == 0 {
                    dc = ch - prev_char
                }

                w->uint(dl)
                w->uint(dc)
                w->uint(utf16_len(&f->text, seg, stop - seg))
                w->uint((*all)[i].kind as usize)
                w->uint((*all)[i].mods as usize)
                prev_line = line
                prev_char = ch
            }

            if (line + 1) >= f->lines.line_count() {
                break
            }

            seg = f->lines.starts[line + 1]
        }
    }

    w->end_array()
}

/// The `tokens` of file \p fid from the raw lex alone, for a buffer that
/// does not parse (the syntax-only worker): no identifier is classified,
/// and an f-string is one string.
pub fn lexical_tokens(sm: unsafe *SourceManager, fid: u32, f: *const FileText, w: *JsonWriter) {
    var all: [SemTok]
    var unsafe *diag = kairo::std::create<DiagEngine>()
    var unsafe *imm  = kairo::std::create<ImmediateTable>()
    imm->initialize(sm)
    var unsafe *lx = kairo::std::create<Lexer>(sm, &null, diag, imm)
    finally {
        kairo::std::destroy(lx)
        kairo::std::destroy(imm)
        diag->clear_retained()
        kairo::std::destroy(diag)
    }

    if lx->open(fid) {
        var t = Token()
        while lx->next(&t) {
            if t.kind == TokenKind::TkEof {
                break
            }

            var r = sm->resolve(t.range.start)
            if (!t.range.start.is_valid()) || ((r.fid as u32) != fid) {
                continue
            }

            var off = r.offset as u32
            var len = t.range.size() as u32
            var mods: u32 = 0
            var kind = lexical_kind(t, &f->text, off, len, &mods)
            if kind == TT_NONE() {
                continue
            }

            var st = SemTok{}
            st.off  = off
            st.len  = len
            st.kind = kind
            st.mods = mods
            all.push_back(st)
        }

        lx->close()
    }

    encode_tokens(&all, f, w)
}

/// Sorts \p keys ascending (a bottom-up merge sort: the tree has no sort).
pub fn sort_u64(keys: *[u64]) {
    var n = keys->size()
    if n < 2 {
        return
    }

    var tmp: [u64]
    tmp.resize(n)
    var width: usize = 1
    while width < n {
        var lo: usize = 0
        while lo < n {
            var mid = lo + width
            if mid > n {
                mid = n
            }

            var hi = lo + (width * 2)
            if hi > n {
                hi = n
            }

            var a = lo
            var b = mid
            var k = lo
            while (a < mid) && (b < hi) {
                if (*keys)[a] <= (*keys)[b] {
                    tmp[k] = (*keys)[a]
                    a += 1
                } else {
                    tmp[k] = (*keys)[b]
                    b += 1
                }

                k += 1
            }

            while a < mid {
                tmp[k] = (*keys)[a]
                a += 1
                k += 1
            }

            while b < hi {
                tmp[k] = (*keys)[b]
                b += 1
                k += 1
            }

            lo = hi
        }

        for var q: usize = 0; q < n; ++q {
            (*keys)[q] = tmp[q]
        }

        width = width * 2
    }
}

/// \class IndexWalker
/// \brief the walk over one TU.
pub class IndexWalker derives RecursiveASTVisitor<IndexWalker> {
    pub var sc:  unsafe *SemaContext
    pub var sm:  unsafe *SourceManager
    pub var fid: u32 = u32::MAX

    pub var toks:   [SemTok]
    pub var refs:   [RefRow]
    pub var syms:   [SymRow]
    pub var inlays: [InlayRow]
    pub var items:  [ItemRow]
    pub var hovers: [string]
    pub var links:  [LinkRow]
    pub var bases:  [BaseRow]

    /// A marker was found: `items` is the answer to a completion request.
    pub var completed: bool = false

    /// Files rows point into, the indexed file first.
    pub var files: [FileText]

    /// decl address -> index into `hovers`: a declaration's hover is built
    /// once however many times it is used.
    priv var hover_of_: {u64: u32}

    /// byte offset of a callee name -> modifiers its call site adds. Filled
    /// by the call and operator visits, merged when tokens are written; the
    /// name itself is classified by the identifier visit, which may run
    /// before or after.
    priv var extra_mods_: {u32: u32}

    /// Locals and parameters seen so far, in walk order: what an unqualified
    /// completion offers before the file's own names.
    priv var locals_: [unsafe *Decl]

    /// File-, module- and type-level declarations seen so far. A top-level
    /// `const` is in no DeclContext list a completion can read, so the walk
    /// keeps its own.
    priv var globals_: [unsafe *Decl]

    /// The function whose body the walk is in, for its enclosing type.
    priv var cur_fn_: unsafe *Declarations::FunctionDecl = &null

    priv var tu_: TypeUtil

    pub fn IndexWalker(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self.tu_ = TypeUtil(sc)
        self.ctx = sc->ctx
        self.sm  = sc->ctx->sm
    }

    // --- driver ----------------------------------------------------------

    pub fn run(self, fid: u32) {
        self.fid = fid
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
            return
        }

        self.file_(fid)

        for var i: usize = 0; i < tu->imports.size(); ++i {
            self.import_(*tu->imports.get(i))
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); i++ {
            var item = *items->get(i)
            match item.kind {
                case TopLevelKind::Decl {
                    self.dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dispatch_expr(item.as_expr())
                }
            }
        }
    }

    // --- locations -------------------------------------------------------

    /// The FileText for \p fid, loading it on first use. Index into `files`.
    priv fn file_(self, fid: u32) -> usize {
        for var i: usize = 0; i < self.files.size(); ++i {
            if self.files[i].fid == fid {
                return i
            }
        }

        var f = FileText()
        f.fid  = fid
        f.path = self.sm->get_filename(fid)
        var size = self.sm->get_file_size(fid)
        if size > 0 {
            // The raw bytes. get_text() decodes UTF-8 and keeps one byte per
            // code point (P800), which both corrupts the text and shifts
            // every offset after the first non-ASCII character.
            var view = self.sm->get_view(self.sm->get_range(fid, 0, size))
            f.text = string(unsafe ((view.data() as unsafe *const u8) as *const u8), view.size())
        }

        f.lines.build(f.text)
        self.files.push_back(f)
        return self.files.size() - 1
    }

    /// Byte offset of \p loc when it lies in the indexed file, else u32::MAX.
    /// A token that came out of a macro body, or from an imported template,
    /// lies elsewhere and has no place in this file's tables.
    priv fn own_off_(self, loc: SourceLocation) -> u32 {
        if !loc.is_valid() {
            return u32::MAX
        }

        var r = self.sm->resolve(loc)
        if (r.fid as u32) != self.fid {
            return u32::MAX
        }

        return r.offset as u32
    }

    // --- classification --------------------------------------------------

    priv fn kind_of_(self, d: unsafe *Decl) -> u32 {
        if d == &null {
            return TT_NONE()
        }

        if isa<Declarations::FunctionDecl>(d) {
            var unsafe *f = cast<Declarations::FunctionDecl>(d)
            if f->is_method() {
                return TT_METHOD()
            }

            if (d->semantic_dc != &null) && d->semantic_dc->is_type_scope() {
                return TT_METHOD()
            }

            return TT_FUNCTION()
        }

        if isa<Declarations::VariableDecl>(d) {
            return TT_VARIABLE()
        }

        if isa<Declarations::ParamDecl>(d) {
            if cast<Declarations::ParamDecl>(d)->is_self {
                return TT_SELF()
            }

            return TT_PARAMETER()
        }

        if isa<Declarations::FieldDecl>(d) {
            return TT_PROPERTY()
        }

        if isa<Declarations::GenericParamDecl>(d) {
            return TT_TYPE_PARAM()
        }

        if isa<Declarations::ClassDecl>(d) {
            return TT_CLASS()
        }

        if isa<Declarations::StructDecl>(d) {
            return TT_STRUCT()
        }

        if isa<Declarations::UnionDecl>(d) {
            return TT_UNION()
        }

        if isa<Declarations::InterfaceDecl>(d) {
            return TT_INTERFACE()
        }

        if isa<Declarations::EnumDecl>(d) {
            return TT_ENUM()
        }

        if isa<Declarations::EnumVariantDecl>(d) {
            return TT_ENUM_MEMBER()
        }

        if isa<Declarations::TypeAliasDecl>(d) {
            return TT_TYPE_ALIAS()
        }

        if isa<Declarations::ModuleDecl>(d) {
            return TT_NAMESPACE()
        }

        if isa<Declarations::MacroDecl>(d) || isa<Declarations::ProcedureMacroDecl>(d) {
            return TT_MACRO()
        }

        return TT_NONE()
    }

    priv fn mods_of_(self, d: unsafe *Decl) -> u32 {
        var m: u32 = 0
        if d == &null {
            return m
        }

        if isa<Declarations::VariableDecl>(d) {
            var unsafe *v = cast<Declarations::VariableDecl>(d)
            if (v->storage == Declarations::StorageClass::Const) || (v->storage == Declarations::StorageClass::Eval) {
                m = m | TM_READONLY() | TM_CONSTANT()
            } else if v->const_binding {
                m = m | TM_READONLY()
            }

            if v->storage == Declarations::StorageClass::Static {
                m = m | TM_STATIC()
            }
        } else if isa<Declarations::FieldDecl>(d) {
            var unsafe *f = cast<Declarations::FieldDecl>(d)
            if (f->storage == Declarations::StorageClass::Const) || (f->storage == Declarations::StorageClass::Eval) {
                m = m | TM_READONLY() | TM_CONSTANT()
            }

            if f->is_static() {
                m = m | TM_STATIC()
            }
        } else if isa<Declarations::ParamDecl>(d) {
            if cast<Declarations::ParamDecl>(d)->is_const {
                m = m | TM_READONLY()
            }
        } else if isa<Declarations::FunctionDecl>(d) {
            var unsafe *f = cast<Declarations::FunctionDecl>(d)
            if f->where_lead != &null {
                m = m | TM_DISPATCHED()
            }

            if (d->semantic_dc != &null) && d->semantic_dc->is_type_scope() && (!f->is_method()) {
                m = m | TM_STATIC()
            }
        } else if isa<Declarations::ClassDecl>(d) {
            if cast<Declarations::ClassDecl>(d)->is_abstract {
                m = m | TM_ABSTRACT()
            }
        }

        if decl_is_ffi(d) {
            m = m | TM_FFI()
        }

        return m
    }

    /// LSP SymbolKind for the outline.
    priv fn symbol_kind_(self, d: unsafe *Decl) -> u32 {
        var k = self.kind_of_(d)
        if k == TT_FUNCTION() {
            return 12
        }

        if k == TT_METHOD() {
            return 6
        }

        if k == TT_VARIABLE() {
            if (self.mods_of_(d) & TM_CONSTANT()) != 0 {
                return 14
            }

            return 13
        }

        if k == TT_PROPERTY() {
            return 8
        }

        if k == TT_CLASS() {
            return 5
        }

        if (k == TT_STRUCT()) || (k == TT_UNION()) {
            return 23
        }

        if k == TT_INTERFACE() {
            return 11
        }

        if k == TT_ENUM() {
            return 10
        }

        if k == TT_ENUM_MEMBER() {
            return 22
        }

        if k == TT_NAMESPACE() {
            return 3
        }

        if k == TT_TYPE_ALIAS() {
            return 5
        }

        if k == TT_TYPE_PARAM() {
            return 26
        }

        return 0
    }

    /// LSP CompletionItemKind.
    priv fn item_kind_(self, d: unsafe *Decl) -> u32 {
        var k = self.kind_of_(d)
        if k == TT_FUNCTION() {
            return 3
        }

        if k == TT_METHOD() {
            return 2
        }

        if (k == TT_VARIABLE()) || (k == TT_PARAMETER()) || (k == TT_SELF()) {
            if (self.mods_of_(d) & TM_CONSTANT()) != 0 {
                return 21
            }

            return 6
        }

        if k == TT_PROPERTY() {
            return 5
        }

        if k == TT_CLASS() {
            return 7
        }

        if (k == TT_STRUCT()) || (k == TT_UNION()) {
            return 22
        }

        if k == TT_INTERFACE() {
            return 8
        }

        if k == TT_ENUM() {
            return 13
        }

        if k == TT_ENUM_MEMBER() {
            return 20
        }

        if k == TT_NAMESPACE() {
            return 9
        }

        if k == TT_TYPE_PARAM() {
            return 25
        }

        if k == TT_MACRO() {
            return 15
        }

        return 1
    }

    // --- hover -----------------------------------------------------------

    /// A type as a diagnostic spells it. Through TypeUtil, not TypePrinter:
    /// an inferred type is a canonical node with no source form, and only
    /// the Sema printer knows how to spell those.
    priv fn type_str_(self, t: unsafe *Type, ctx: unsafe *ASTContext) -> string {
        if (t == &null) || (ctx == &null) {
            return ""
        }

        // `Self` as written: the printer resolves it to whatever it stands
        // for, and an interface's `fn op +(self, Self) -> Self` must not read
        // as if it named the interface.
        if isa<Types::SelfType>(t) {
            return "Self"
        }

        var s = self.tu_.str(t)
        if s.starts_with("<") {
            // "<unknown>", "<error>": nothing a reader can use.
            return ""
        }

        return s
    }

    /// The declaration as one line of Kairo: what a hover shows in its code
    /// block and a completion item shows as its detail.
    priv fn signature_(self, d: unsafe *Decl) -> string {
        if d == &null {
            return ""
        }

        var unsafe *ctx = NameLookup::ctx_of(d)
        if ctx == &null {
            ctx = self.ctx
        }

        var name = sema_dump_decl_name(ctx, d)

        if isa<Declarations::FunctionDecl>(d) {
            var unsafe *f = cast<Declarations::FunctionDecl>(d)
            var s: string = "fn "
            s += name
            s += "("
            for var i: usize = 0; i < f->params.size(); ++i {
                var unsafe *p = f->params[i]
                if i > 0 {
                    s += ", "
                }

                if p->is_const {
                    s += "const "
                }

                if p->is_self {
                    s += "self"
                    continue
                }

                // A requirement may leave a parameter unnamed (`fn op + (self,
                // Self)`): the type alone is its spelling.
                // An unnamed parameter has no name TOKEN either, and asking for
                // the spelling of an empty token is an ICE: test first.
                var pt = self.type_str_(p->type_, ctx)
                if p->unname || (!p->name.range.start.is_valid()) {
                    s += pt
                    continue
                }

                var pn = ctx->get_spelling(p->name)
                if pn.empty() || pn.starts_with("$") {
                    s += pt
                    continue
                }

                s += pn
                if !pt.empty() {
                    s += ": "
                    s += pt
                }
            }

            s += ")"
            var rt = self.type_str_(f->return_type, ctx)
            if (!rt.empty()) && (rt != "void") {
                s += " -> "
                s += rt
            }

            if f->where_lead != &null {
                s += "  // where-dispatched"
            }

            return s
        }

        if isa<Declarations::VariableDecl>(d) {
            var unsafe *v = cast<Declarations::VariableDecl>(d)
            var s: string = "var "
            if v->storage == Declarations::StorageClass::Const {
                s = "const "
            } else if v->storage == Declarations::StorageClass::Static {
                s = "static "
            } else if v->storage == Declarations::StorageClass::Eval {
                s = "eval "
            }

            s += name
            var t = self.type_str_(v->type_, ctx)
            if !t.empty() {
                s += ": "
                s += t
            }

            return s
        }

        if isa<Declarations::ParamDecl>(d) {
            var unsafe *p = cast<Declarations::ParamDecl>(d)
            var s: string = "(parameter) "
            if p->is_self {
                return s + "self"
            }

            s += name
            var t = self.type_str_(p->type_, ctx)
            if !t.empty() {
                s += ": "
                s += t
            }

            return s
        }

        if isa<Declarations::FieldDecl>(d) {
            var unsafe *f = cast<Declarations::FieldDecl>(d)
            var s: string = "var "
            s += name
            var t = self.type_str_(f->type_, ctx)
            if !t.empty() {
                s += ": "
                s += t
            }

            return s
        }

        if isa<Declarations::TypeAliasDecl>(d) {
            var s: string = "type "
            s += name
            var t = self.type_str_(cast<Declarations::TypeAliasDecl>(d)->aliased, ctx)
            if !t.empty() {
                s += " = "
                s += t
            }

            return s
        }

        // A variant names the enum it belongs to and carries its value or
        // payload: hovering `Green` alone does not say which enum or which
        // number it is.
        if isa<Declarations::EnumVariantDecl>(d) {
            var s: string = "(variant) "
            if (d->semantic_dc != &null) && (d->semantic_dc->dc_owner != &null)
                && isa<Declarations::EnumDecl>(d->semantic_dc->dc_owner) {
                s += sema_dump_decl_name(ctx, d->semantic_dc->dc_owner)
                s += "::"
            }

            return s + self.variant_line_(cast<Declarations::EnumVariantDecl>(d), ctx)
        }

        // An enum's underlying type is part of what it is (its size, what
        // `as` gives); a plain enum without `derives` is u32 by the rule in
        // enums-plain.
        if isa<Declarations::EnumDecl>(d) {
            var unsafe *e = cast<Declarations::EnumDecl>(d)
            var s: string = "enum "
            s += name
            if e->underlying != &null {
                var t = self.type_str_(e->underlying, ctx)
                if !t.empty() {
                    s += " derives "
                    s += t
                }
            } else if !e->is_adt {
                s += " derives u32 /* default */"
            }

            return s
        }

        var kw: string = ""
        if isa<Declarations::ClassDecl>(d) {
            kw = "class "
        } else if isa<Declarations::StructDecl>(d) {
            kw = "struct "
        } else if isa<Declarations::UnionDecl>(d) {
            kw = "union "
        } else if isa<Declarations::InterfaceDecl>(d) {
            kw = "interface "
        } else if isa<Declarations::EnumDecl>(d) {
            kw = "enum "
        } else if isa<Declarations::EnumVariantDecl>(d) {
            kw = "(variant) "
        } else if isa<Declarations::ModuleDecl>(d) {
            kw = "module "
        } else if isa<Declarations::GenericParamDecl>(d) {
            kw = "(type parameter) "
        } else if isa<Declarations::MacroDecl>(d) {
            kw = "macro "
        }

        return kw + name
    }

    /// The `///` lines directly above \p d, markers stripped, joined by
    /// newlines.
    ///
    /// Read from the TEXT, not from the tree: under --preserve-comments the
    /// tree carried doc comments for some library declarations and for none
    /// of a project file's (P799), and the flag also turns a test file's
    /// `// RUN:` lines into annotations. The lines above a name are
    /// exactly what a reader calls its documentation.
    priv fn doc_(self, d: unsafe *Decl) -> string {
        var out: string = ""
        var name = decl_name_tok(d)
        var at   = name.range.start
        if !at.is_valid() {
            at = d->range.start
        }

        if !at.is_valid() {
            return out
        }

        var res  = self.sm->resolve(at)
        var fi   = self.file_(res.fid as u32)
        var line = self.files[fi].lines.line_of(res.offset as usize)

        // Walk up over the block: `///` lines, and attribute lines between
        // the comment and the declaration (`@inline`, a visibility keyword
        // on its own line).
        var first = line
        var lines: [string]
        while first > 0 {
            var ls = self.files[fi].lines.starts[first - 1]
            var le = self.files[fi].lines.line_end(self.files[fi].text, first - 1)
            var p  = ls
            while (p < le) && ((self.files[fi].text[p] == 32) || (self.files[fi].text[p] == 9)) {
                p += 1
            }

            if ((p + 2) < le) && (self.files[fi].text[p] == 47) && (self.files[fi].text[p + 1] == 47)
                && (self.files[fi].text[p + 2] == 47) {
                p += 3
                if (p < le) && (self.files[fi].text[p] == 32) {
                    p += 1
                }

                lines.push_back(self.files[fi].text.subslice(p, le - p))
                first -= 1
                continue
            }

            if ((p + 2) == le) && (self.files[fi].text[p] == 47) && (self.files[fi].text[p + 1] == 47) {
                break // a bare `//` ends a doc block
            }

            if (p < le) && (self.files[fi].text[p] == 64) && lines.empty() {
                first -= 1 // an attribute line above the declaration
                continue
            }

            break
        }

        // A license banner is not documentation: the block that opens a file
        // with a `/// ---` rule belongs to the file.
        if (!lines.empty()) && lines[lines.size() - 1].starts_with("--- ") {
            return out
        }

        var n = lines.size()
        for var i: usize = 0; i < n; ++i {
            if i > 0 {
                out += "\n"
            }

            out += lines[n - 1 - i]
        }

        return out
    }

    /// For a type: its body as a reader wants it on hover. An interface lists
    /// every requirement, the inherited ones too (the inlay hint that shows
    /// them is one line and editors cut it short). A class, struct or union
    /// lists its fields and methods, then the methods `extend` blocks add.
    /// Empty for anything that is not a type.
    priv fn members_(self, d: unsafe *Decl) -> string {
        var lines: [string]
        if isa<Declarations::InterfaceDecl>(d) {
            var unsafe *it = cast<Declarations::InterfaceDecl>(d)
            for var i: usize = 0; i < it->methods.size(); ++i {
                lines.push_back("    " + self.signature_(unsafe (it->methods[i] as unsafe *Decl)))
            }

            var inherited: [string]
            self.inherited_methods_(d, 0, &inherited)
            for var i: usize = 0; i < inherited.size(); ++i {
                var line = "    " + inherited[i]
                var dup = false
                for var k: usize = 0; k < lines.size(); ++k {
                    if lines[k] == line {
                        dup = true
                    }
                }

                if !dup {
                    lines.push_back(line + "  // inherited")
                }
            }
        } else if isa<Declarations::ClassDecl>(d) || isa<Declarations::StructDecl>(d) || isa<Declarations::UnionDecl>(d) {
            var fields: [unsafe *Decl]
            var meths:  [unsafe *Decl]
            if isa<Declarations::ClassDecl>(d) {
                var unsafe *c = cast<Declarations::ClassDecl>(d)
                for var i: usize = 0; i < c->fields.size(); ++i {
                    fields.push_back(unsafe (c->fields[i] as unsafe *Decl))
                }
            } else if isa<Declarations::StructDecl>(d) {
                var unsafe *c = cast<Declarations::StructDecl>(d)
                for var i: usize = 0; i < c->fields.size(); ++i {
                    fields.push_back(unsafe (c->fields[i] as unsafe *Decl))
                }
            } else {
                var unsafe *c = cast<Declarations::UnionDecl>(d)
                for var i: usize = 0; i < c->fields.size(); ++i {
                    fields.push_back(unsafe (c->fields[i] as unsafe *Decl))
                }
            }

            self.methods_of_(d, &meths)
            if isa<Declarations::UnionDecl>(d) {
                var unsafe *c = cast<Declarations::UnionDecl>(d)
                for var i: usize = 0; i < c->methods.size(); ++i {
                    meths.push_back(unsafe (c->methods[i] as unsafe *Decl))
                }
            }

            for var i: usize = 0; (i < fields.size()) && (lines.size() < 40); ++i {
                if !fields[i]->is_implicit {
                    lines.push_back("    " + self.signature_(fields[i]))
                }
            }

            for var i: usize = 0; (i < meths.size()) && (lines.size() < 40); ++i {
                if !meths[i]->is_implicit {
                    lines.push_back("    " + self.signature_(meths[i]))
                }
            }

            // What `extend` blocks add, from every file of the build: an
            // extension is found by the type it targets, not by an import.
            var fids = self.sc->g->all_fids()
            for var fi: usize = 0; (fi < fids.size()) && (lines.size() < 60); ++fi {
                var unsafe *octx = self.sc->g->get_context(fids[fi])
                if (octx == &null) || (octx->tu == &null) {
                    continue
                }

                var *decls = &octx->tu->dc_decls
                for var k: usize = 0; k < decls->size(); ++k {
                    var unsafe *e = *decls->get(k)
                    if (e == &null) || (!isa<Declarations::ExtensionDecl>(e)) {
                        continue
                    }

                    var unsafe *ext = cast<Declarations::ExtensionDecl>(e)
                    if self.decl_of_type_(ext->target) != d {
                        continue
                    }

                    for var m: usize = 0; (m < ext->methods.size()) && (lines.size() < 60); ++m {
                        lines.push_back("    " + self.signature_(unsafe (ext->methods[m] as unsafe *Decl)) + "  // extend")
                    }
                }
            }
        } else if isa<Declarations::EnumDecl>(d) {
            var unsafe *e = cast<Declarations::EnumDecl>(d)
            var unsafe *ctx = NameLookup::ctx_of(d)
            if ctx == &null {
                ctx = self.ctx
            }

            for var i: usize = 0; (i < e->variants.size()) && (lines.size() < 60); ++i {
                lines.push_back("    " + self.variant_line_(e->variants[i], ctx))
            }
        } else {
            return ""
        }

        if lines.empty() {
            return " { }"
        }

        var out: string = " {"
        for var i: usize = 0; i < lines.size(); ++i {
            out += "\n"
            out += lines[i]
        }

        out += "\n}"
        return out
    }

    /// One variant as it reads in its enum: `Name { a: T, b: U }` for a
    /// payload, `Name = 3` for a plain variant whose value Sema computed
    /// (implicit values too: the reader wants the number, not the rule).
    priv fn variant_line_(self, v: unsafe *Declarations::EnumVariantDecl, ctx: unsafe *ASTContext) -> string {
        var s: string = sema_dump_decl_name(ctx, unsafe (v as unsafe *Decl))
        if v->payload.size() > 0 {
            s += " { "
            for var k: usize = 0; k < v->payload.size(); ++k {
                var unsafe *f = v->payload[k]
                if k > 0 {
                    s += ", "
                }

                s += sema_dump_decl_name(ctx, unsafe (f as unsafe *Decl))
                var t = self.type_str_(f->type_, ctx)
                if !t.empty() {
                    s += ": "
                    s += t
                }
            }

            s += " }"
            return s
        }

        if v->value.ok {
            s += " = "
            if v->value.neg {
                s += "-"
            }

            var mag = v->value.mag
            s += f"{mag}"
        }

        return s
    }

    /// Size and alignment in bytes of a field of type \p t, when they follow
    /// from arithmetic alone: a builtin, a pointer, a plain enum, or a record
    /// made of those. False for anything whose layout the C++ side decides.
    priv fn field_layout_(self, t_in: unsafe *Type, size: *u64, align: *u64, depth: u32) -> bool {
        if (t_in == &null) || (depth > 6) {
            return false
        }

        var unsafe *t = t_in
        if t->canonical != &null {
            t = t->canonical
        }

        t = canon_unqual(t)
        if t == &null {
            return false
        }

        if isa<RecordType>(t) {
            return self.record_layout_(cast<RecordType>(t)->decl, size, align, depth + 1)
        }

        if isa<Types::NullableType>(t) {
            return false // carries a presence flag whose placement lowering decides
        }

        if (t->size_bits == 0) || (t->align_bits == 0) || ((t->size_bits % 8) != 0) {
            return false
        }

        (*size)  = (t->size_bits / 8) as u64
        (*align) = (t->align_bits / 8) as u64
        return true
    }

    /// A struct's or plain class's layout by the C rule: each field at the
    /// next multiple of its alignment, the whole rounded up to the largest.
    /// Refuses anything the rule does not cover (bases, virtual methods,
    /// generics, layout attributes, ADT enums), so a number shown is right.
    priv fn record_layout_(self, d: unsafe *Decl, size: *u64, align: *u64, depth: u32) -> bool {
        if (d == &null) || (depth > 6) || decl_is_ffi(d) {
            return false
        }

        var fields: [unsafe *Decl]
        var is_union = false
        if isa<Declarations::ClassDecl>(d) {
            var unsafe *c = cast<Declarations::ClassDecl>(d)
            if (c->derives_list.size() > 0) || (c->generic_params.size() > 0) || c->is_abstract {
                return false
            }

            for var i: usize = 0; i < c->methods.size(); ++i {
                if (c->methods[i]->abi == Declarations::AbiKind::Virtual)
                    || (c->methods[i]->body_kind == Declarations::FnBodyKind::Virtual) {
                    return false // a virtual method adds a vtable pointer
                }
            }

            for var i: usize = 0; i < c->fields.size(); ++i {
                fields.push_back(unsafe (c->fields[i] as unsafe *Decl))
            }
        } else if isa<Declarations::StructDecl>(d) {
            var unsafe *c = cast<Declarations::StructDecl>(d)
            if c->generic_params.size() > 0 {
                return false
            }

            for var i: usize = 0; i < c->fields.size(); ++i {
                fields.push_back(unsafe (c->fields[i] as unsafe *Decl))
            }
        } else if isa<Declarations::UnionDecl>(d) {
            var unsafe *c = cast<Declarations::UnionDecl>(d)
            is_union = true
            for var i: usize = 0; i < c->fields.size(); ++i {
                fields.push_back(unsafe (c->fields[i] as unsafe *Decl))
            }
        } else if isa<Declarations::EnumDecl>(d) {
            var unsafe *e = cast<Declarations::EnumDecl>(d)
            if e->is_adt {
                return false
            }

            if e->underlying == &null {
                (*size)  = 4
                (*align) = 4
                return true
            }

            return self.field_layout_(e->underlying, size, align, depth + 1)
        } else {
            return false
        }

        if d->annotations.size() > 0 {
            return false // @packed / @align and friends change the rule
        }

        var off: u64 = 0
        var max: u64 = 1
        for var i: usize = 0; i < fields.size(); ++i {
            var unsafe *f = cast<Declarations::FieldDecl>(fields[i])
            if f->is_static() || f->is_bitfield {
                if f->is_bitfield {
                    return false
                }

                continue
            }

            var fs: u64 = 0
            var fa: u64 = 0
            if !self.field_layout_(f->type_, &fs, &fa, depth + 1) {
                return false
            }

            if fa > max {
                max = fa
            }

            if is_union {
                if fs > off {
                    off = fs
                }
            } else {
                off = ((off + fa - 1) / fa) * fa
                off += fs
            }
        }

        if off == 0 {
            off = 1 // an empty record still has an address
        }

        (*size)  = ((off + max - 1) / max) * max
        (*align) = max
        return true
    }

    /// "size N, align M" for a type declaration, or "" when not known.
    priv fn layout_(self, d: unsafe *Decl) -> string {
        if !(isa<Declarations::ClassDecl>(d) || isa<Declarations::StructDecl>(d) || isa<Declarations::UnionDecl>(d)
            || isa<Declarations::EnumDecl>(d)) {
            return ""
        }

        var size:  u64 = 0
        var align: u64 = 0
        if !self.record_layout_(d, &size, &align, 0) {
            return ""
        }

        return f"size {size} bytes, align {align}"
    }

    /// Index of \p d's hover text in `hovers`, building it on first use.
    priv fn hover_(self, d: unsafe *Decl) -> u32 {
        var key = (d as usize) as u64
        var hit = self.hover_of_.get(key)
        if hit != null {
            return *hit
        }

        var sig = self.signature_(d)
        var md: string = "```kairo\n"
        md += sig
        md += self.members_(d)
        md += "\n```"

        var lay = self.layout_(d)
        if !lay.empty() {
            md += "\n\n"
            md += lay
        }

        // Where it lives, when that is a type or a module: `Foo::bar` reads
        // differently from a free `bar`.
        if (d->semantic_dc != &null) && (d->semantic_dc->dc_owner != &null) {
            var unsafe *owner = d->semantic_dc->dc_owner
            var on = sema_dump_decl_name(self.ctx, owner)
            if (!on.empty()) && (!isa<Declarations::FunctionDecl>(owner)) {
                md += "\n\nin `"
                md += on
                md += "`"
            }
        }

        var doc = self.doc_(d)
        if !doc.empty() {
            md += "\n\n---\n\n"
            md += doc
        }

        self.hovers.push_back(md)
        var idx = (self.hovers.size() - 1) as u32
        self.hover_of_[key] = idx
        return idx
    }

    // --- emitting --------------------------------------------------------

    priv fn tok_(self, off: u32, len: u32, kind: u32, mods: u32) {
        if (off == u32::MAX) || (len == 0) || (kind == TT_NONE()) {
            return
        }

        var t = SemTok{}
        t.off  = off
        t.len  = len
        t.kind = kind
        t.mods = mods
        self.toks.push_back(t)
    }

    /// Records a use of \p d at \p tok: a token, and an edge to the declaration.
    priv fn use_(self, tok_in: Token, d: unsafe *Decl, extra: u32) {
        if d == &null {
            return
        }

        var tok = self.ctx->unwrap_token(tok_in)
        var off = self.own_off_(tok.range.start)
        if off == u32::MAX {
            return
        }

        var len = tok.range.size() as u32
        self.tok_(off, len, self.kind_of_(d), self.mods_of_(d) | extra)

        var r = RefRow{}
        r.off = off
        r.len = len
        self.target_(d, &r)
        self.refs.push_back(r)
    }

    /// The type a constructor constructs, or null when \p d is not one. A
    /// constructor is a function declared in a type under the type's name.
    priv fn ctor_owner_(self, d: unsafe *Decl) -> unsafe *Decl {
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
    priv fn target_(self, d: unsafe *Decl, r: *RefRow) {
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
    priv fn value_type_(self, d: unsafe *Decl) -> unsafe *Type {
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
    priv fn type_decl_(self, t_in: unsafe *Type, depth: u32) -> unsafe *Decl {
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
    priv fn declare_(self, d: unsafe *Decl) {
        if (d == &null) || d->is_implicit {
            return
        }

        var kind = self.kind_of_(d)
        if kind == TT_NONE() {
            return
        }

        var name = self.ctx->unwrap_token(decl_name_tok(d))
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
        s.name    = self.ctx->get_spelling(name)
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

    /// `import a::b::c`: each segment is a namespace token.
    priv fn import_(self, d: unsafe *Decl) {
        if (d == &null) || (!isa<Declarations::ImportDecl>(d)) {
            return
        }

        var unsafe *im = cast<Declarations::ImportDecl>(d)
        if im->is_prelude {
            return
        }

        for var i: usize = 0; i < im->path_segments.size(); ++i {
            var t = im->path_segments[i]
            self.tok_(self.own_off_(t.range.start), t.range.size() as u32, TT_NAMESPACE(), 0)
        }

        // The path is a link to the file it resolved to. An ffi import names
        // a header clang found; where is not recorded on the import.
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
    priv fn is_overloaded_(self, f: unsafe *Declarations::FunctionDecl) -> bool {
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
    priv fn mark_call_(self, tok_in: Token, d: unsafe *Decl) {
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

        if m == 0 {
            return
        }

        var tok = self.ctx->unwrap_token(tok_in)
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

    /// A user-defined operator at \p tok: an operator token that reads as a
    /// call, and jumps to the `op` function.
    priv fn user_op_(self, tok: Token, d: unsafe *Decl) {
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

    priv fn is_marker_(self, n: unsafe *NamedIdentExpr) -> bool {
        if n == &null {
            return false
        }

        return self.ctx->get_spelling(n->name) == completion_marker()
    }

    priv fn item_(self, d: unsafe *Decl, sort: u32) {
        if (d == &null) || d->is_implicit {
            return
        }

        var unsafe *ctx = NameLookup::ctx_of(d)
        if ctx == &null {
            ctx = self.ctx
        }

        var name = sema_dump_decl_name(ctx, d)
        if name.empty() || name.starts_with("op ") || (name == completion_marker()) {
            return
        }

        // Leading-underscore names are reserved for interop and trailing
        // underscores mark a file's private helpers: neither is something to
        // offer from another file.
        if name.starts_with("_") || name.ends_with("_") {
            if NameLookup::ctx_of(d) != self.ctx {
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
    priv fn items_of_context_(self, dc: unsafe *DeclContext, sort: u32) {
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
    priv fn items_of_tu_(self, tu: unsafe *TranslationUnit, sort: u32) {
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
    priv fn context_of_decl_(self, d: unsafe *Decl) -> unsafe *DeclContext {
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
    priv fn items_of_type_(self, t_in: unsafe *Type, depth: u32) {
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

    priv fn items_of_record_(self, d: unsafe *Decl, depth: u32) {
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
    priv fn complete_member_(self, recv_type: unsafe *Type, recv_decl: unsafe *Decl) {
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
    priv fn complete_scope_(self) {
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

    priv fn overlay_rows_(self, tu: unsafe *TranslationUnit) {
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

    pub fn visit_decl(self, n: *Decl) -> bool {
        var unsafe *d = unsafe (n as unsafe *Decl)
        if isa<Declarations::FunctionDecl>(d) {
            self.cur_fn_ = cast<Declarations::FunctionDecl>(d)
        }

        self.declare_(d)

        // A declaration whose type was inferred shows it as an inlay hint.
        // Sema writes the inferred type back with no source range, which is
        // how an inferred slot is told from a written one.
        if isa<Declarations::VariableDecl>(d) {
            var unsafe *v = cast<Declarations::VariableDecl>(d)
            if (v->type_ != &null) && (!v->type_->range.is_valid()) && (!d->is_implicit) {
                var name = self.ctx->unwrap_token(v->name)
                var off  = self.own_off_(name.range.end)
                var txt  = self.type_str_(v->type_, self.ctx)
                if (off != u32::MAX) && (!txt.empty()) {
                    var row = InlayRow{}
                    row.off   = off
                    row.label = ": " + txt
                    self.inlays.push_back(row)
                }
            }
        }

        self.bases_of_(d)
        return true
    }

    /// The declaration a written type names: a path's last segment, or the
    /// record behind a canonical type.
    priv fn decl_of_type_(self, t: unsafe *Type) -> unsafe *Decl {
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

    priv fn base_edge_(self, d: unsafe *Decl, base: unsafe *Type, inherited: *[unsafe *Decl]) {
        var unsafe *bd = self.decl_of_type_(base)
        if bd == &null {
            return
        }

        inherited->push_back(bd)

        var name = self.ctx->unwrap_token(decl_name_tok(d))
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
        row.name      = sema_dump_decl_name(self.ctx, d)
        row.base_name = sema_dump_decl_name(self.ctx, bd)
        row.kind      = self.symbol_kind_(d)
        row.base_kind = self.symbol_kind_(bd)
        self.bases.push_back(row)
    }

    /// Every requirement an interface gets from the interfaces it derives,
    /// nearest first, each once.
    priv fn inherited_methods_(self,
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
    priv fn methods_of_(self, d: unsafe *Decl, out: *[unsafe *Decl]) {
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
    priv fn method_edges_(self, d: unsafe *Decl, inherited: *[unsafe *Decl]) {
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

                var mn = sema_dump_decl_name(self.ctx, mine[i])
                for var k: usize = 0; k < theirs.size(); ++k {
                    if sema_dump_decl_name(self.ctx, theirs[k]) != mn {
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
    priv fn bases_of_(self, d: unsafe *Decl) {
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

            var name = self.ctx->unwrap_token(c->name)
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

    /// `name:` before each argument of a call to \p d, as an editor shows a
    /// parameter hint. Not where it would say nothing: an argument that is
    /// already named, or is a variable called what the parameter is.
    priv fn param_hints_(self, c: unsafe *Expressions::CallExpr, d: unsafe *Decl) {
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
            if pn.empty() || pn.starts_with("$") || pn.starts_with("_") {
                continue
            }

            if isa<NamedIdentExpr>(arg) && (self.ctx->get_spelling(cast<NamedIdentExpr>(arg)->name) == pn) {
                continue
            }

            var off = self.own_off_(arg->range.start)
            if off == u32::MAX {
                continue
            }

            var row = InlayRow{}
            row.off       = off
            row.label     = pn + ":"
            row.kind      = 2
            row.pad_right = true
            self.inlays.push_back(row)
        }
    }

    pub fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        var unsafe *e = unsafe (n as unsafe *NamedIdentExpr)
        if self.is_marker_(e) {
            self.complete_scope_()
            return true
        }

        if e->is_bound() {
            self.use_(e->name, e->resolved_decl, 0)
        } else if e->variant_decl != &null {
            self.use_(e->name, e->variant_decl, 0)
        }

        return true
    }

    pub fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        var unsafe *c = unsafe (n as unsafe *ChainExpr)
        for var i: usize = 0; i < c->steps.size(); ++i {
            var unsafe *st = c->steps.get(i)
            if st->name == &null {
                continue
            }

            if self.is_marker_(st->name) {
                // What is to the left of the cursor: the previous step, or the
                // chain's base when this is the first step.
                var rt: unsafe *Type = &null
                var rd: unsafe *Decl = &null
                if i > 0 {
                    var unsafe *prev = c->steps.get(i - 1)
                    rt = prev->resolved_type
                    rd = prev->resolved_decl
                } else if c->base != &null {
                    rt = c->base->type_
                    if isa<NamedIdentExpr>(c->base) {
                        rd = cast<NamedIdentExpr>(c->base)->resolved_decl
                    }
                }

                self.complete_member_(rt, rd)
                continue
            }

            if st->resolved_decl != &null {
                self.use_(st->name->name, st->resolved_decl, 0)
            }
        }

        return true
    }

    pub fn visit_chain_type(self, n: *Types::ChainType) -> bool {
        var unsafe *c = unsafe (n as unsafe *Types::ChainType)
        for var i: usize = 0; i < c->segments.size(); ++i {
            var unsafe *sg = c->segments.get(i)
            if sg->name == &null {
                continue
            }

            if self.is_marker_(sg->name) {
                if i > 0 {
                    var unsafe *prev = c->segments.get(i - 1)
                    self.complete_member_(prev->resolved_type, prev->resolved_decl)
                } else {
                    self.complete_scope_()
                }

                continue
            }

            if sg->resolved_decl != &null {
                self.use_(sg->name->name, sg->resolved_decl, 0)
            }
        }

        return true
    }

    pub fn visit_call_expr(self, n: *Expressions::CallExpr) -> bool {
        var unsafe *c = unsafe (n as unsafe *Expressions::CallExpr)
        if c->callee == &null {
            return true
        }

        var callee: unsafe *Decl = &null
        if isa<NamedIdentExpr>(c->callee) {
            var unsafe *id = cast<NamedIdentExpr>(c->callee)
            self.mark_call_(id->name, id->resolved_decl)
            callee = id->resolved_decl
        } else if isa<ChainExpr>(c->callee) {
            var unsafe *ch = cast<ChainExpr>(c->callee)
            if ch->steps.size() > 0 {
                var unsafe *last = ch->steps.get(ch->steps.size() - 1)
                if last->name != &null {
                    self.mark_call_(last->name->name, last->resolved_decl)
                }

                callee = last->resolved_decl
            }
        }

        // `Point(1, 2)` names the type; the constructor it picked is on the call.
        if (callee == &null) || (!isa<Declarations::FunctionDecl>(callee)) {
            callee = c->ctor_decl
        }

        self.param_hints_(c, callee)

        return true
    }

    pub fn visit_binary_operator_expr(self, n: *Expressions::BinaryOperatorExpr) -> bool {
        self.user_op_(n->op_token, n->resolved_op)
        return true
    }

    pub fn visit_assign_operator_expr(self, n: *Expressions::AssignOperatorExpr) -> bool {
        self.user_op_(n->op_token, n->resolved_op)
        return true
    }

    pub fn visit_unary_operator_expr(self, n: *Expressions::UnaryOperatorExpr) -> bool {
        self.user_op_(n->op_token, n->resolved_op)
        return true
    }

    // --- output ----------------------------------------------------------

    /// Lexes the file for what the tree does not carry (keywords, literals,
    /// comments, operators) and merges the tree's classifications over the
    /// identifiers. \p out receives every token, sorted by offset.
    priv fn lexical_(self, out: *[SemTok]) {
        // offset -> index into toks, for identifiers the walk classified. A
        // name can be visited twice (a callee is a name and a call); the
        // first classification stands and call modifiers are merged below.
        var by_off: {u32: u32}
        for var i: usize = 0; i < self.toks.size(); ++i {
            if by_off.get(self.toks[i].off) == null {
                by_off[self.toks[i].off] = i as u32
            }
        }

        // A throwaway engine: this lex repeats the one the compiler already
        // ran, and its diagnostics were reported then.
        var unsafe *diag = kairo::std::create<DiagEngine>()
        var unsafe *imm  = kairo::std::create<ImmediateTable>()
        imm->initialize(self.sm)
        var unsafe *lx = kairo::std::create<Lexer>(self.sm, &null, diag, imm)
        finally {
            kairo::std::destroy(lx)
            kairo::std::destroy(imm)
            diag->clear_retained()
            kairo::std::destroy(diag)
        }

        if !lx->open(self.fid) {
            return
        }

        var t = Token()
        while lx->next(&t) {
            if t.kind == TokenKind::TkEof {
                break
            }

            var off = self.own_off_(t.range.start)
            if off == u32::MAX {
                continue
            }

            var len = t.range.size() as u32
            var hit = by_off.get(off)
            if hit != null {
                var st = self.toks[*hit as usize]
                var em = self.extra_mods_.get(off)
                if em != null {
                    st.mods = st.mods | *em
                }

                out->push_back(st)
                continue
            }

            // An f-string is ONE token to the lexer, and the names inside its
            // `{...}` are classified by the walk like any others. Emitting the
            // literal whole would bury them under a string colour; instead
            // the text is a string, and each interpolation is code.
            if (t.kind == TokenKind::LitString) && self.interpolated_(off, len, &by_off, out) {
                continue
            }

            var mods: u32 = 0
            var kind = lexical_kind(t, &self.files[0].text, off, len, &mods)
            if kind == TT_NONE() {
                continue
            }

            var st = SemTok{}
            st.off  = off
            st.len  = len
            st.kind = kind
            st.mods = mods
            out->push_back(st)
        }

        lx->close()
    }

    /// Splits the string literal at [off, off+len) around its `{...}`
    /// interpolations. False when it has none the walk classified (a plain
    /// string, or braces that are just text), and the caller emits it whole.
    priv fn interpolated_(self,
                          off:    u32,
                          len:    u32,
                          by_off: *{u32: u32},
                          out:    *[SemTok]) -> bool {
        var *text = &self.files[0].text
        var end = (off + len) as usize
        if end > text->size() {
            return false
        }

        // Only worth splitting when some classified name lies inside.
        var any = false
        for var p: usize = off as usize; p < end; ++p {
            if by_off->get(p as u32) != null {
                any = true
                break
            }
        }

        if !any {
            return false
        }

        var seg = off as usize // start of the pending string piece
        var p   = off as usize
        while p < end {
            if (*text)[p] != 123 {
                p += 1
                continue
            }

            // The matching `}` of this interpolation (nested braces count).
            var depth: usize = 1
            var q = p + 1
            while (q < end) && (depth > 0) {
                if (*text)[q] == 123 {
                    depth += 1
                } else if (*text)[q] == 125 {
                    depth -= 1
                }

                q += 1
            }

            if depth != 0 {
                break
            }

            // string text up to and including the `{`
            self.piece_(seg, p + 1, TT_STRING(), out)

            // the expression: names the walk knew, numbers, and operators
            var c = p + 1
            var stop = q - 1
            while c < stop {
                var ch = (*text)[c]
                var hit = by_off->get(c as u32)
                if hit != null {
                    var st = self.toks[*hit as usize]
                    var em = self.extra_mods_.get(c as u32)
                    if em != null {
                        st.mods = st.mods | *em
                    }

                    out->push_back(st)
                    c += st.len as usize
                    continue
                }

                if (ch >= 48) && (ch <= 57) {
                    var ne = c
                    while (ne < stop) && ((((*text)[ne] >= 48) && ((*text)[ne] <= 57)) || ((*text)[ne] == 46)
                        || ((*text)[ne] == 95) || (((*text)[ne] >= 97) && ((*text)[ne] <= 122))) {
                        ne += 1
                    }

                    self.piece_(c, ne, TT_NUMBER(), out)
                    c = ne
                    continue
                }

                if ((ch >= 97) && (ch <= 122)) || ((ch >= 65) && (ch <= 90)) || (ch == 95) {
                    // A word the walk did not classify: a keyword (`as`,
                    // `if`) or an unresolved name. Left to the grammar.
                    while (c < stop) && (((*text)[c] >= 48 && (*text)[c] <= 57) || ((*text)[c] >= 97 && (*text)[c] <= 122)
                        || ((*text)[c] >= 65 && (*text)[c] <= 90) || ((*text)[c] == 95)) {
                        c += 1
                    }

                    continue
                }

                if (ch == 43) || (ch == 45) || (ch == 42) || (ch == 47) || (ch == 37) || (ch == 60) || (ch == 62)
                    || (ch == 61) || (ch == 33) || (ch == 38) || (ch == 124) || (ch == 94) || (ch == 63) {
                    self.piece_(c, c + 1, TT_OPERATOR(), out)
                }

                c += 1
            }

            seg = q - 1 // the `}` starts the next string piece
            p   = q
        }

        self.piece_(seg, end, TT_STRING(), out)
        return true
    }

    priv fn piece_(self, from: usize, to: usize, kind: u32, out: *[SemTok]) {
        if to <= from {
            return
        }

        var st = SemTok{}
        st.off  = from as u32
        st.len  = (to - from) as u32
        st.kind = kind
        st.mods = 0
        out->push_back(st)
    }

    priv fn is_word_(self, off: u32) -> bool {
        var c = self.files[0].text[off as usize]
        return ((c >= 97) && (c <= 122)) || ((c >= 65) && (c <= 90)) || (c == 95)
    }

    /// UTF-16 length of bytes [off, off+len) of file \p fi.
    priv fn len16_(self, fi: usize, off: usize, len: usize) -> usize {
        var units: usize = 0
        var i   = off
        var end = off + len
        var *text = &self.files[fi].text
        if end > text->size() {
            end = text->size()
        }

        while i < end {
            var c = (*text)[i]
            if c >= 0xF0 {
                i     += 4
                units += 2
            } else if c >= 0xE0 {
                i     += 3
                units += 1
            } else if c >= 0xC0 {
                i     += 2
                units += 1
            } else {
                i     += 1
                units += 1
            }
        }

        return units
    }

    /// Writes `"line":L,"character":C` members for byte \p off of file \p fi.
    priv fn pos_(self, w: *JsonWriter, fi: usize, off: usize) {
        var line = self.files[fi].lines.line_of(off)
        w->field_uint("line", line)
        w->field_uint("character", self.files[fi].lines.character(self.files[fi].text, off, false))
    }

    priv fn range_(self, w: *JsonWriter, fi: usize, off: usize, len: usize) {
        w->begin_object()
        w->key("start")
        w->begin_object()
        self.pos_(w, fi, off)
        w->end_object()
        w->key("end")
        w->begin_object()
        self.pos_(w, fi, off + len)
        w->end_object()
        w->end_object()
    }

    /// Spacing for a spelled-back expansion: none inside `a.b`, `a::b`,
    /// `f(x)`, `v[i]`, before `,` and `;`; one space elsewhere. The lexer
    /// keeps no inter-token whitespace, so this is a reading aid, as
    /// `--dump-preprocessed` is (which puts one space everywhere).
    priv fn glue_(self, const prev: string, const cur: string) -> bool {
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
            return ((c >= 97) && (c <= 122)) || ((c >= 65) && (c <= 90)) || ((c >= 48) && (c <= 57))
                || (c == 95) || (c == 41) || (c == 93) || (c == 33)
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
    priv fn macros_(self, w: *JsonWriter) {
        w->key("macros")
        w->begin_array()
        if (self.ctx == &null) || (self.ctx->tcm == &null) {
            w->end_array()
            return
        }

        var unsafe *tcm = self.ctx->tcm
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
                var u = self.ctx->unwrap_token(t)
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

    /// Writes this file's index as one JSON object into \p w.
    pub fn write(self, w: *JsonWriter) {
        w->begin_object()
        w->field("path", self.files[0].path)

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

        w->key("refs")
        w->begin_array()
        for var oi: usize = 0; oi < order.size(); ++oi {
            var r = self.refs[(order[oi] & 0xFFFFFFFF) as usize]
            w->begin_array()
            var line = self.files[0].lines.line_of(r.off as usize)
            w->uint(line)
            w->uint(self.files[0].lines.character(self.files[0].text, r.off as usize, false))
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
                w->uint(self.files[fi].lines.character(self.files[fi].text, r.def_off as usize, false))
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
                w->uint(self.files[ti].lines.character(self.files[ti].text, r.type_off as usize, false))
                w->uint(self.len16_(ti, r.type_off as usize, r.type_len as usize))
            }

            w->uint(r.kind as usize)
            w->end_array()
        }

        w->end_array()

        // --- bases: [line, char, len, baseFile, baseLine, baseChar, baseLen, name, baseName, kind, baseKind]
        w->key("bases")
        w->begin_array()
        for var i: usize = 0; i < self.bases.size(); ++i {
            var b = self.bases[i]
            var bi = self.file_(b.base_fid)
            w->begin_array()
            w->uint(self.files[0].lines.line_of(b.off as usize))
            w->uint(self.files[0].lines.character(self.files[0].text, b.off as usize, false))
            w->uint(self.len16_(0, b.off as usize, b.len as usize))
            w->uint(bi)
            w->uint(self.files[bi].lines.line_of(b.base_off as usize))
            w->uint(self.files[bi].lines.character(self.files[bi].text, b.base_off as usize, false))
            w->uint(self.len16_(bi, b.base_off as usize, b.base_len as usize))
            w->str(b.name)
            w->str(b.base_name)
            w->uint(b.kind as usize)
            w->uint(b.base_kind as usize)
            w->end_array()
        }

        w->end_array()

        // --- links: [line, char, len, target path]
        w->key("links")
        w->begin_array()
        for var i: usize = 0; i < self.links.size(); ++i {
            w->begin_array()
            w->uint(self.files[0].lines.line_of(self.links[i].off as usize))
            w->uint(self.files[0].lines.character(self.files[0].text, self.links[i].off as usize, false))
            w->uint(self.len16_(0, self.links[i].off as usize, self.links[i].len as usize))
            w->str(self.links[i].target)
            w->end_array()
        }

        w->end_array()

        self.macros_(w)

        w->key("files")
        w->begin_array()
        for var i: usize = 0; i < self.files.size(); ++i {
            w->str(self.files[i].path)
        }

        w->end_array()

        w->key("hovers")
        w->begin_array()
        for var i: usize = 0; i < self.hovers.size(); ++i {
            w->str(self.hovers[i])
        }

        w->end_array()

        // --- outline: flat, in source order; the server nests by range.
        w->key("symbols")
        w->begin_array()
        for var i: usize = 0; i < self.syms.size(); ++i {
            var s = self.syms[i]
            w->begin_object()
            w->field("name", s.name)
            if !s.detail.empty() {
                w->field("detail", s.detail)
            }

            w->field_uint("kind", s.kind as usize)
            w->key("range")
            self.range_(w, 0, s.start as usize, (s.end - s.start) as usize)
            w->key("selectionRange")
            self.range_(w, 0, s.sel_off as usize, s.sel_len as usize)
            w->end_object()
        }

        w->end_array()

        w->key("inlays")
        w->begin_array()
        for var i: usize = 0; i < self.inlays.size(); ++i {
            w->begin_object()
            w->key("position")
            w->begin_object()
            self.pos_(w, 0, self.inlays[i].off as usize)
            w->end_object()
            w->field("label", self.inlays[i].label)
            if self.inlays[i].kind != 0 {
                w->field_uint("kind", self.inlays[i].kind as usize)
            }

            if self.inlays[i].pad_left {
                w->field_bool("paddingLeft", true)
            }

            if self.inlays[i].pad_right {
                w->field_bool("paddingRight", true)
            }

            w->end_object()
        }

        w->end_array()

        if self.completed {
            w->key("items")
            w->begin_array()
            for var i: usize = 0; i < self.items.size(); ++i {
                var it = self.items[i]
                w->begin_object()
                w->field("label", it.label)
                w->field_uint("kind", it.kind as usize)
                if !it.detail.empty() {
                    w->field("detail", it.detail)
                }

                // sortText orders groups (locals before members before
                // imports); within a group the editor sorts by label.
                w->field("sortText", f"{it.sort}{it.label}")
                if !it.doc.empty() {
                    w->field("doc", it.doc)
                }

                w->end_object()
            }

            w->end_array()
        }

        w->end_object()
    }
}
