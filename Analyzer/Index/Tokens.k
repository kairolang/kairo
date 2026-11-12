/// --- The Kairo Project ----------------------- Analyzer/Index/Tokens.k --- ///
///
///   Semantic tokens: the lexical pass, interpolated strings, delta encoding.
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
import AST::LangItems::{
    LangIntrinsics,
    LangMacros,
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
import Index::Writer::*
import Json::JsonWriter
import Lexer::Immediate::{
    Immediate,
    ImmediateTable,
}
import Lexer::Lexer::{
    Lexer,
    chain_head_len,
}
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
import Token::TokenKind::{
    TokenKind,
    is_keyword,
}
import Token::TokenText::TokenText

/// UTF-16 length of bytes [off, off+len) of \p text.
pub fn utf16_len(text: *const string, off: usize, len: usize) -> usize {
    var units: usize = 0
    var i            = off
    var end          = off + len
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

    if t.kind == TokenKind::KwUnsafe {
        *mods = TM_UNSAFE()
        return TT_KEYWORD()
    }

    if is_keyword(t.kind) || (t.kind == TokenKind::LitNull) {
        return TT_KEYWORD()
    }

    if t.kind == TokenKind::LitIdentifier {
        return TT_NONE() // left to the walk, or to the editor's grammar
    }

    if (len > 0) && ((off as usize) < text->size()) {
        // A word that is neither identifier nor keyword is a primitive type
        // name (`i32`, `bool`, `usize`) or `Self`. A primitive is a keyword
        // of the language and takes the STANDARD keyword type, so every
        // client colours it as one without a rule of its own. `Self` keeps
        // its own type (and with it the colour it shares with `self`).
        var c = (*text)[off as usize]
        if ((c >= ('a' as u8)) && (c <= ('z' as u8)))
            || ((c >= ('A' as u8)) && (c <= ('Z' as u8)))
            || (c == ('_' as u8)) {
            *mods = TM_DEFAULT_LIB()
            if (len == 4) && (text->subslice(off as usize, 4) == "Self") {
                return TT_BUILTIN()
            }

            return TT_KEYWORD()
        }
    }

    return TT_NONE()
}

/// \p word names a builtin macro or a parser `name!` intrinsic (the
/// names the preprocessor reserves, so no user macro shares one).
pub fn is_builtin_macro_name(const word: string) -> bool {
    var i: usize = 0
    while true {
        var w = LangMacros::known(i)
        if w.empty() {
            break
        }

        if w == word {
            return true
        }

        i += 1
    }

    i = 0
    while true {
        var w = LangIntrinsics::known(i)
        if w.empty() {
            break
        }

        if w == word {
            return true
        }

        i += 1
    }

    return false
}

/// The length of the `macro` token for identifier \p t at [off, off+len)
/// of \p text, its `!` included, or 0 when no `!` follows the name
/// directly. A name followed by `!` is a macro wherever it is written: an
/// invocation (`name!(...)`, `name! {...}`, `name!`, `a::name!`), a
/// definition (`macro name!`), an import (`import lib::name!`). Both token
/// passes read it from the raw lex, so it does not change when the file
/// stops parsing. `x!=y` is a comparison, not a macro.
pub fn macro_token_len(t: Token, text: *const string, off: u32, len: u32) -> u32 {
    if t.kind != TokenKind::LitIdentifier {
        return 0
    }

    var end = (off as usize) + (len as usize)
    if (end >= text->size()) || ((*text)[end] != ('!' as u8)) {
        return 0
    }

    if ((end + 1) < text->size()) && ((*text)[end + 1] == ('=' as u8)) {
        return 0
    }

    return len + 1
}

/// The modifiers of the macro name at [off, off+len) of \p text, after a
/// token of kind \p prev: `declaration` + `definition` after `macro`;
/// `defaultLibrary` on an unqualified builtin (a qualified `a::file!` is a
/// user macro).
pub fn macro_token_mods(text: *const string, off: u32, len: u32, prev: TokenKind) -> u32 {
    if prev == TokenKind::KwMacro {
        return TM_DECLARATION() | TM_DEFINITION()
    }

    if (off > 0) && ((*text)[(off as usize) - 1] == (':' as u8)) {
        return 0
    }

    if is_builtin_macro_name(text->subslice(off as usize, len as usize)) {
        return TM_DEFAULT_LIB()
    }

    return 0
}

/// Writes \p all (sorted, in bytes of \p f) as the `tokens` array: LSP's
/// relative five-integer encoding, one token per line of a multi-line one.
pub fn encode_tokens(all: *const [SemTok], f: *const FileText, w: *JsonWriter) {
    w->key(SK_TOKENS)
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
    var        all:  [SemTok]
    var unsafe *diag          = kairo::std::create<DiagEngine>()
    var unsafe *imm           = kairo::std::create<ImmediateTable>()
    imm->initialize(sm)
    var unsafe *lx = kairo::std::create<Lexer>(sm, &null, diag, imm)
    finally {
        kairo::std::destroy(lx)
        kairo::std::destroy(imm)
        diag->clear_retained()
        kairo::std::destroy(diag)
    }

    if lx->open(fid) {
        var t    = Token()
        var prev = TokenKind::TkEof
        while lx->next(&t) {
            if t.kind == TokenKind::TkEof {
                break
            }

            var r = sm->resolve(t.range.start)
            if (!t.range.start.is_valid()) || ((r.fid as u32) != fid) {
                continue
            }

            var off       = r.offset as u32
            var len       = chain_head_len(imm, t, t.range.size() as u32)
            var mods: u32 = 0
            var kind      = lexical_kind(t, &f->text, off, len, &mods)
            var ml        = macro_token_len(t, &f->text, off, len)
            if ml != 0 {
                mods = macro_token_mods(&f->text, off, len, prev)
                kind = TT_MACRO()
                len  = ml
            }

            if t.kind != TokenKind::AtComment {
                prev = t.kind
            }

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

extend IndexWalker {
    /// Lexes the file for what the tree does not carry (keywords, literals,
    /// comments, operators) and merges the tree's classifications over the
    /// identifiers. \p out receives every token, sorted by offset.
    fn lexical_(self, out: *[SemTok]) {
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

        var t    = Token()
        var prev = TokenKind::TkEof
        while lx->next(&t) {
            if t.kind == TokenKind::TkEof {
                break
            }

            var off = self.own_off_(t.range.start)
            if off == u32::MAX {
                continue
            }

            var tk = prev
            if t.kind != TokenKind::AtComment {
                prev = t.kind
            }

            var len = chain_head_len(imm, t, t.range.size() as u32)

            // A macro name is the raw lex's, as in the syntax-only pass: the
            // tree keeps no invocation, and an import path's last segment
            // `name!` would otherwise read as a module.
            var ml = macro_token_len(t, &self.files[0].text, off, len)
            if ml != 0 {
                var st = SemTok{}
                st.off  = off
                st.len  = ml
                st.kind = TT_MACRO()
                st.mods = macro_token_mods(&self.files[0].text, off, len, tk)
                out->push_back(st)
                continue
            }

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
                self.chained_(imm, t, off + len, &by_off, out)
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
            if t.kind == TokenKind::LitString {
                self.chained_(imm, t, off + len, &by_off, out)
            }
        }

        lx->close()
    }

    /// Splits the string literal at [off, off+len) around its `{...}`
    /// interpolations. False when it has none the walk classified (a plain
    /// string, or braces that are just text), and the caller emits it whole.
    fn interpolated_(self, off: u32, len: u32, by_off: *{u32: u32}, out: *[SemTok]) -> bool {
        var *text = &self.files[0].text
        var end   = (off + len) as usize
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
            if (*text)[p] != ('{' as u8) {
                p += 1
                continue
            }

            // The matching `}` of this interpolation (nested braces count).
            var depth: usize = 1
            var q            = p + 1
            while (q < end) && (depth > 0) {
                if (*text)[q] == ('{' as u8) {
                    depth += 1
                } else if (*text)[q] == ('}' as u8) {
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
            var c    = p + 1
            var stop = q - 1
            while c < stop {
                var ch  = (*text)[c]
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

                if (ch >= ('0' as u8)) && (ch <= ('9' as u8)) {
                    var ne = c
                    while (ne < stop)
                        && ((((*text)[ne] >= ('0' as u8)) && ((*text)[ne] <= ('9' as u8)))
                            || ((*text)[ne] == ('.' as u8))
                            || ((*text)[ne] == ('_' as u8))
                            || (((*text)[ne] >= ('a' as u8)) && ((*text)[ne] <= ('z' as u8)))) {
                        ne += 1
                    }

                    self.piece_(c, ne, TT_NUMBER(), out)
                    c = ne
                    continue
                }

                if ((ch >= ('a' as u8)) && (ch <= ('z' as u8)))
                    || ((ch >= ('A' as u8)) && (ch <= ('Z' as u8)))
                    || (ch == ('_' as u8)) {
                    // A word the walk did not classify: a keyword (`as`,
                    // `if`) or an unresolved name. Left to the grammar.
                    while (c < stop)
                        && (((*text)[c] >= ('0' as u8) && (*text)[c] <= ('9' as u8))
                            || ((*text)[c] >= ('a' as u8) && (*text)[c] <= ('z' as u8))
                            || ((*text)[c] >= ('A' as u8) && (*text)[c] <= ('Z' as u8))
                            || ((*text)[c] == ('_' as u8))) {
                        c += 1
                    }

                    continue
                }

                if (ch == ('+' as u8))
                    || (ch == ('-' as u8))
                    || (ch == ('*' as u8))
                    || (ch == ('/' as u8))
                    || (ch == ('%' as u8))
                    || (ch == ('<' as u8))
                    || (ch == ('>' as u8))
                    || (ch == ('=' as u8))
                    || (ch == ('!' as u8))
                    || (ch == ('&' as u8))
                    || (ch == ('|' as u8))
                    || (ch == ('^' as u8))
                    || (ch == ('?' as u8)) {
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

    /// The segments chained after string token \p t (`"a" f"b{x}"`):
    /// the lexer makes no token of them, so each is found from its
    /// StringData and emitted like a literal of its own, holes split out.
    /// \p from is where the token ends; each segment starts at the first
    /// byte past the blanks after the one before it.
    fn chained_(self,
                imm:    unsafe *ImmediateTable,
                t:      Token,
                from:   u32,
                by_off: *{u32: u32},
                out:    *[SemTok]) {
        var        *text = &self.files[0].text
        var unsafe *seg  = imm->get<Immediate::StringData>(t.imm)
        var        at    = from as usize
        while (seg != &null) && (seg->next != u32::MAX) {
            seg = imm->get<Immediate::StringData>(seg->next)
            if seg == &null {
                return
            }

            while (at < text->size())
                && (((*text)[at] == (' ' as u8))
                    || ((*text)[at] == ('\t' as u8))
                    || ((*text)[at] == ('\n' as u8))
                    || ((*text)[at] == ('\r' as u8))) {
                at += 1
            }

            var bs = self.own_off_(seg->body.start)
            var be = self.own_off_(seg->body.end)
            if (bs == u32::MAX) || (be == u32::MAX) || ((bs as usize) < at) {
                return
            }

            // The opening quotes run from the prefix's end (or the segment's
            // start) to the body; the closing run is as long.
            var qs = at as u32
            if !seg->prefix_kind.empty() {
                var pe = self.own_off_(seg->prefix.range.end)
                if pe != u32::MAX {
                    qs = pe
                }
            }

            var end = be + (bs - qs)
            if seg->suffix.range.is_valid() {
                var se = self.own_off_(seg->suffix.range.end)
                if se != u32::MAX {
                    end = se
                }
            }

            var len = end - (at as u32)
            if !self.interpolated_(at as u32, len, by_off, out) {
                self.piece_(at, end as usize, TT_STRING(), out)
            }

            at = end as usize
        }
    }

    fn piece_(self, from: usize, to: usize, kind: u32, out: *[SemTok]) {
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
}
