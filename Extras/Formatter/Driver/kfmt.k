/// --- The Kairo Project ----------------------------------- Extras/Formatter/Driver/kfmt.k --- ///
///
///   kfmt: AST + raw tokens -> Doc IR -> text.
///
///   The AST decides layout: blocks, statement / member / item lists, call and
///   parameter lists, `&&` / `||` chains, alignment runs. Everything the AST
///   cannot reproduce exactly is printed as the source bytes, re-indented:
///   leaves, control-flow headers, types, patterns, closures, macro
///   invocations. Comments, blank lines, imports, macro declarations and
///   anything else the parser keeps out of the lists come from a second, raw
///   lex of the file. Code found between list elements is printed as written.
///
///   No token is printed through the interner. get_spelling rewrites `0xFF`
///   as `255` and `and` as `&&`; every token here is its own source bytes.
///
///   Nothing is written unless the output re-lexes to the same code tokens
///   (with the same non-blank text between them) and the same comments in the
///   same order. That check, not the printer, is what makes write-back safe.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/Support/raw_ostream.h";
ffi "c++" import "Native/KLocale.hh";      // init_process_locale
ffi "c++" import "llvm/Support/InitLLVM.h";
ffi "c++" import "llvm/Support/TargetSelect.h";

import Driver::CompilerInstance::*;
import Driver::TUStage::*;
import Tooling::ParseAPI::*;
import Tooling::ToolDiagnostics::*;
import Support::FileIO::Path::*;
import Diagnostic::Severity::*;

import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::ASTSupport::*;
import AST::Context::TranslationUnit::*;
import AST::Mixin::Annotation::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Types::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import Location::SourceManager::*;
import Location::SourceLocation::*;
import Location::SourceRange::*;
import Lexer::Lexer::*;
import Lexer::Immediate::*;
import Token::Token::*;
import Token::TokenKind::*;
import Resolution::ModulePath::*;
import Diagnostic::Consumer::*;

import DocIR::*;
import Renderer::*;

enum FmtMode derives u8 {
    Check,    ///< list files that would change; exit 1 if any
    Write,    ///< rewrite them in place
    Stdout,   ///< print the formatted file
}

/// One raw token: what the AST does not keep.
struct RawTok {
    var kind:  TokenKind;
    var start: u32;
    var end:   u32;
}

/// One element of a list, before layout.
struct Entry {
    var doc:        Doc;            ///< the element, its `;` / `,` included
    var key:        Doc;            ///< alignable: before the sep
    var val:        Doc;            ///< alignable: after the sep
    var sep:        string = "";    ///< alignable when non-empty
    var first:      usize  = 0;     ///< source line of its first byte
    var last:       usize  = 0;     ///< source line of its last byte
    var is_comment: bool   = false;
}

/// One thing a list holds, as the AST names it. Exactly one pointer is set.
struct Elem {
    var start:   u32 = 0;
    var end:     u32 = 0;
    var decl:    *Decl            = &null;
    var stmt:    *Stmt            = &null;
    var expr:    *Expr            = &null;
    var variant: *EnumVariantDecl = &null;
    var mcase:   *MatchCase       = &null;
}

struct ListOut {
    var head:  Doc;          ///< a comment on the opener's line, as a line suffix
    var body:  Doc;
    var empty: bool = true;
}

/// Lexes \p fid on its own, comments and newlines included.
fn lex_file(ci: *CompilerInstance, fid: u32, out: *vec::<RawTok>) -> bool {
    var imm = std::create::<ImmediateTable>();
    imm->initialize(ci->sm());
    var lx = std::create::<Lexer>(ci->sm(), ci->pool(), ci->diag(), imm);
    finally {
        std::destroy(lx);
        std::destroy(imm);
    }

    if !lx->open(fid) { return false; }

    var t = Token();
    while lx->next(&t) {
        if t.kind == TokenKind::TkEof { break; }
        out->push_back(RawTok { kind: t.kind, start: t.range.start.raw(), end: t.range.end.raw() });
    }

    lx->close();
    return true;
}

class Formatter {
    pub var ctx:  obs::<ASTContext>;
    pub var ci:   obs::<CompilerInstance>;
    pub var sm:   obs::<SourceManager>;
    pub var fid:  u32 = 0;
    pub var base: u32 = 0;              ///< raw location of byte 0
    pub var size: u32 = 0;              ///< file size in bytes

    var toks:   vec::<RawTok>;          ///< every token, comments and newlines included
    var cm_lo:  vec::<u32>;             ///< comment starts, ascending
    var ms_lo:  vec::<u32>;             ///< macro invocation sites, ascending, disjoint
    var ms_hi:  vec::<u32>;
    var _depth: i32 = 0;                ///< list nesting, for alignment fits

    fn Formatter(self, ctx: *ASTContext, ci: *CompilerInstance, fid: u32) {
        self.ctx = ctx;
        self.ci  = ci;
        self.sm  = ci->sm();
        self.fid = fid;
    }

    static fn line_width() -> i32 { return 100; }

    /// Rule 3 cap: at most this many consecutive blank lines survive.
    static fn max_blank_lines() -> usize { return 4; }

    // ----------------------------------------------------------------------
    //  Setup
    // ----------------------------------------------------------------------

    fn prepare(self) -> bool {
        self.base = self.sm->get_loc(self.fid, 0).raw();
        self.size = static_cast::<u32>(self.sm->get_file_size(self.fid));
        self.sm->wait_for_line_index(self.fid);

        if !lex_file(self.ci, self.fid, &self.toks) { return false; }

        var n = self.toks.size();
        for var i: usize = 0; i < n; ++i {
            if self.toks[i].kind == TokenKind::AtComment { self.cm_lo.push_back(self.toks[i].start); }
        }

        // `name!` glued, plus a bracket group glued to the `!`
        var i: usize = 0;
        while (i + 1) < n {
            var a = self.toks[i];
            var b = self.toks[i + 1];
            if (a.kind != TokenKind::LitIdentifier) || (b.kind != TokenKind::OpExclaim) || (b.start != a.end) {
                i += 1;
                continue;
            }

            var end = b.end;
            var j   = i + 2;
            if (j < n) && (self.toks[j].start == end) && Formatter::_is_open(self.toks[j].kind) {
                var depth: i32 = 0;
                while j < n {
                    if Formatter::_is_open(self.toks[j].kind)  { depth += 1; }
                    if Formatter::_is_close(self.toks[j].kind) { depth -= 1; }
                    end = self.toks[j].end;
                    j  += 1;
                    if depth == 0 { break; }
                }
            }

            self.ms_lo.push_back(a.start);
            self.ms_hi.push_back(end);
            i = j;
        }

        return true;
    }

    /// The file as it is on disk.
    fn source(self) -> string {
        return self._text(self.base, self.base + self.size);
    }

    fn run(self, prog: *Program) -> string {
        var els = vec::<Elem>();
        for var i: usize = 0; i < prog->items.size(); ++i {
            var item = prog->items.get(i);
            if item == &null { continue; }
            switch item->get_kind() {
                case TopLevelKind::Decl { self._push_decl(item->as_decl(), &els); }
                case TopLevelKind::Stmt { self._push_stmt(item->as_stmt(), &els); }
                case TopLevelKind::Expr {
                    var e = item->as_expr();
                    if e != &null {
                        els.push_back(Elem { start: e->range.start.raw(), end: e->range.end.raw(), expr: e });
                    }
                }
                default {}
            }
        }

        var l = self._list(self.base, self.base + self.size, 0, &els);
        return Renderer::render(&l.body, Formatter::line_width());
    }

    // ----------------------------------------------------------------------
    //  Round-trip check
    // ----------------------------------------------------------------------

    /// \p out re-lexes to the same code and the same comments as the file.
    fn verify(self, out: string, name: string) -> bool {
        var owned = out.std_string();
        var sr    = sref(out);
        var vfid  = self.sm->load_virtual(
            Path(name + ".kfmt", false),
            reinterpret_cast::<std::ConstPtr::<u8>>(sr.data()),
            sr.size()
        );
        if vfid == u32(-1) { return false; }

        var other = vec::<RawTok>();
        if !lex_file(self.ci, vfid, &other) { return false; }

        var code_a = vec::<string>();
        var cmts_a = vec::<string>();
        var code_b = vec::<string>();
        var cmts_b = vec::<string>();
        self._sig_seq(&self.toks, &code_a, &cmts_a);
        self._sig_seq(&other,     &code_b, &cmts_b);

        if (code_a.size() != code_b.size()) || (cmts_a.size() != cmts_b.size()) { return false; }
        for var i: usize = 0; i < code_a.size(); ++i {
            if code_a[i] != code_b[i] { return false; }
        }
        for var i: usize = 0; i < cmts_a.size(); ++i {
            if cmts_a[i] != cmts_b[i] { return false; }
        }
        return true;
    }

    /// Code tokens as text, with any non-blank text the lexer left between two
    /// tokens (a chained string segment) as an item of its own. Comments go
    /// in their own list: rule 4 moves them relative to code, never reorders them.
    priv fn _sig_seq(self, ts: *vec::<RawTok>, code: *vec::<string>, cmts: *vec::<string>) {
        var have = false;
        var prev: u32 = 0;
        for var i: usize = 0; i < ts->size(); ++i {
            var t = (*ts)[i];
            if have {
                var g = self._trimmed(prev, t.start);
                if g.size() > 0 { code->push_back("\x01" + g); }
            }
            prev = t.end;
            have = true;

            if (t.kind == TokenKind::TkNewLine) || (t.kind == TokenKind::TkWhitespace) { continue; }
            if t.kind == TokenKind::AtComment {
                cmts->push_back(self._trimmed(t.start, t.end));
                continue;
            }
            code->push_back(self._text(t.start, t.end));
        }
    }

    // ----------------------------------------------------------------------
    //  Source text and lines
    // ----------------------------------------------------------------------

    priv fn _text(self, a: u32, b: u32) -> string {
        if b <= a { return ""; }
        return self.sm->get_text(SourceRange::from_bounds(SourceLocation::from_raw(a), SourceLocation::from_raw(b)));
    }

    priv fn _tok(self, t: Token) -> string {
        return self._text(t.range.start.raw(), t.range.end.raw());
    }

    priv static fn _ws(c: char) -> bool {
        return (c == ' ') || (c == '\t') || (c == '\n') || (c == '\r');
    }

    /// \p b moved back over trailing whitespace (all of it, or only line
    /// breaks). Whitespace is ASCII, so characters dropped are bytes dropped.
    priv fn _trim_back(self, a: u32, b: u32, spaces_too: bool) -> u32 {
        var t = self._text(a, b);
        var n = t.size();
        var k: usize = 0;
        while k < n {
            var c = t[n - 1 - k];
            var drop = (c == '\n') || (c == '\r') || (spaces_too && ((c == ' ') || (c == '\t')));
            if !drop { break; }
            k += 1;
        }
        return b - static_cast::<u32>(k);
    }

    priv fn _trimmed(self, a: u32, b: u32) -> string {
        var t = self._text(a, b);
        var n = t.size();
        var l: usize = 0;
        while (l < n) && Formatter::_ws(t[l]) { l += 1; }
        if l == n { return ""; }
        var r: usize = 0;
        while (r < n) && Formatter::_ws(t[n - 1 - r]) { r += 1; }
        return self._text(a + static_cast::<u32>(l), b - static_cast::<u32>(r));
    }

    priv fn _line(self, a: u32) -> usize {
        return self.sm->get_line_col(SourceLocation::from_raw(a)).line;
    }

    priv fn _line_start(self, l: usize) -> u32 {
        return self.base + self.sm->_line_table.get_line_offset(self.fid, static_cast::<u32>(l));
    }

    /// End of line \p l, its line break excluded.
    priv fn _line_end(self, l: usize) -> u32 {
        var a = self._line_start(l);
        var b = self.base + self.sm->_line_table.get_line_end_offset(self.fid, static_cast::<u32>(l));
        return self._trim_back(a, b, false);
    }

    /// Bytes of indentation at the start of [a, b).
    priv fn _lead_ws(self, a: u32, b: u32) -> u32 {
        var t = self._text(a, b);
        var k: usize = 0;
        while (k < t.size()) && ((t[k] == ' ') || (t[k] == '\t')) { k += 1; }
        return static_cast::<u32>(k);
    }

    // ----------------------------------------------------------------------
    //  Token index
    // ----------------------------------------------------------------------

    priv static fn _is_open(k: TokenKind) -> bool {
        return (k == TokenKind::OpLParen) || (k == TokenKind::OpLSquare) || (k == TokenKind::OpLBrace);
    }

    priv static fn _is_close(k: TokenKind) -> bool {
        return (k == TokenKind::OpRParen) || (k == TokenKind::OpRSquare) || (k == TokenKind::OpRBrace);
    }

    priv static fn _trivia(k: TokenKind) -> bool {
        return (k == TokenKind::TkNewLine) || (k == TokenKind::TkWhitespace) || (k == TokenKind::AtComment);
    }

    /// Index of the first token starting at or after \p a.
    priv fn _lb(self, a: u32) -> usize {
        var lo: usize = 0;
        var hi        = self.toks.size();
        while lo < hi {
            var mid = lo + ((hi - lo) / 2);
            if self.toks[mid].start < a { lo = mid + 1; } else { hi = mid; }
        }
        return lo;
    }

    /// First code token starting at or after \p a; toks.size() if none.
    priv fn _sig_after(self, a: u32) -> usize {
        var n = self.toks.size();
        for var i = self._lb(a); i < n; ++i {
            if !Formatter::_trivia(self.toks[i].kind) { return i; }
        }
        return n;
    }

    /// Last code token ending at or before \p b; toks.size() if none.
    priv fn _sig_before(self, b: u32) -> usize {
        var i = self._lb(b);
        while i > 0 {
            i -= 1;
            if (self.toks[i].end <= b) && (!Formatter::_trivia(self.toks[i].kind)) { return i; }
        }
        return self.toks.size();
    }

    priv fn _comment_in(self, a: u32, b: u32) -> bool {
        var lo: usize = 0;
        var hi        = self.cm_lo.size();
        while lo < hi {
            var mid = lo + ((hi - lo) / 2);
            if self.cm_lo[mid] < a { lo = mid + 1; } else { hi = mid; }
        }
        return (lo < self.cm_lo.size()) && (self.cm_lo[lo] < b);
    }

    /// The macro site overlapping [a, b), or ms_lo.size().
    priv fn _macro_at(self, a: u32, b: u32) -> usize {
        var lo: usize = 0;
        var hi        = self.ms_hi.size();
        while lo < hi {
            var mid = lo + ((hi - lo) / 2);
            if self.ms_hi[mid] <= a { lo = mid + 1; } else { hi = mid; }
        }
        if (lo < self.ms_lo.size()) && (self.ms_lo[lo] < b) { return lo; }
        return self.ms_lo.size();
    }

    priv fn _macro_in(self, a: u32, b: u32) -> bool {
        return self._macro_at(a, b) < self.ms_lo.size();
    }

    /// Any code token in [a, b).
    priv fn _has_sig(self, a: u32, b: u32) -> bool {
        var i = self._sig_after(a);
        return (i < self.toks.size()) && (self.toks[i].start < b);
    }

    priv fn _kind_at(self, i: usize) -> TokenKind {
        if i >= self.toks.size() { return TokenKind::TkUnknown; }
        return self.toks[i].kind;
    }

    /// The last code token in [a, b) is \p k, or the first one after it is.
    priv fn _has_sep(self, a: u32, b: u32, k: TokenKind) -> bool {
        var l = self._sig_before(b);
        if (l < self.toks.size()) && (self.toks[l].start >= a) && (self.toks[l].kind == k) { return true; }
        return self._kind_at(self._sig_after(b)) == k;
    }

    /// \p b moved back before a trailing `;` or `,` that sits inside [a, b).
    priv fn _core_end(self, a: u32, b: u32) -> u32 {
        var l = self._sig_before(b);
        if (l >= self.toks.size()) || (self.toks[l].start < a) { return b; }
        var k = self.toks[l].kind;
        if (k != TokenKind::OpSemicolon) && (k != TokenKind::OpComma) { return b; }
        var p = self._sig_before(self.toks[l].start);
        if (p >= self.toks.size()) || (self.toks[p].start < a) { return b; }
        return self.toks[p].end;
    }

    /// Past the `;` / `,` glued to the end of an element.
    priv fn _skip_seps(self, b: u32) -> u32 {
        var cur = b;
        var i   = self._lb(b);
        while i < self.toks.size() {
            var k = self.toks[i].kind;
            if (k != TokenKind::OpSemicolon) && (k != TokenKind::OpComma) { break; }
            cur = self.toks[i].end;
            i  += 1;
        }
        return cur;
    }

    // ----------------------------------------------------------------------
    //  Source text as Docs
    // ----------------------------------------------------------------------

    /// [a, b) as written. Continuation lines keep their indentation relative
    /// to the first line's and follow the output indent. A multi-line string
    /// or char literal in the range pins every line to column 0 instead:
    /// re-indenting it would change its value.
    priv fn _v(self, a: u32, b: u32) -> Doc {
        if b <= a { return Doc::nothing(); }

        var l1 = self._line(a);
        var l2 = self._line(b - 1);
        if l1 == l2 { return Doc::text(self._text(a, b)); }

        var exact = self._has_ml_literal(a, b);
        var base  = self._lead_ws(self._line_start(l1), self._line_end(l1));
        var parts = vec::<Doc>();

        var e1 = self._line_end(l1);
        if !exact { e1 = self._trim_back(a, e1, true); }
        parts.push_back(Doc::text(self._text(a, e1)));

        for var l = l1 + 1; l <= l2; ++l {
            var ls = self._line_start(l);
            var le = (b) if (l == l2) else (self._line_end(l));

            if exact {
                parts.push_back(Doc::literal_line());
                parts.push_back(Doc::text(self._text(ls, le)));
                continue;
            }

            le = self._trim_back(ls, le, true);
            var ws = self._lead_ws(ls, le);
            parts.push_back(Doc::hardline());
            if (ls + ws) >= le { continue; }   // blank: no indent written

            var cut = (ws) if (ws < base) else (base);
            parts.push_back(Doc::text(self._text(ls + cut, le)));
        }

        return Doc::concat(parts);
    }

    priv fn _has_ml_literal(self, a: u32, b: u32) -> bool {
        for var i = self._lb(a); i < self.toks.size(); ++i {
            var t = self.toks[i];
            if t.start >= b { break; }
            if (t.kind != TokenKind::LitString) && (t.kind != TokenKind::LitChar) { continue; }
            if self._line(t.start) != self._line(t.end - 1) { return true; }
        }
        return false;
    }

    /// The tokens in [a, b) as written, whitespace at both ends dropped.
    priv fn _span(self, a: u32, b: u32) -> Doc {
        var n = self.toks.size();
        var i = self._lb(a);
        while (i < n) && (self.toks[i].kind == TokenKind::TkNewLine) { i += 1; }
        if (i >= n) || (self.toks[i].start >= b) { return Doc::nothing(); }

        var j = self._lb(b);
        while j > i {
            var t = self.toks[j - 1];
            if (t.kind != TokenKind::TkNewLine) && (t.end <= b) { break; }
            j -= 1;
        }
        if j <= i { return Doc::text(self._text(self.toks[i].start, self.toks[i].end)); }
        return self._v(self.toks[i].start, self.toks[j - 1].end);
    }

    priv fn _semi(self, has: bool) -> Doc {
        return (Doc::text(";")) if (has) else (Doc::nothing());
    }

    /// Rule 1: one item per line when the list does not fit.
    priv fn _seq(self, open: string, items: vec::<Doc>, close: string, trail: bool) -> Doc {
        if items.empty() { return Doc::text(open + close); }

        var inner = vec::<Doc>();
        inner.push_back(Doc::softline());
        for var i: usize = 0; i < items.size(); ++i {
            if i > 0 {
                inner.push_back(Doc::text(","));
                inner.push_back(Doc::line());
            }
            inner.push_back(items[i]);
        }
        if trail { inner.push_back(Doc::text(",")); }

        return Doc::group(Doc::concat4(
            Doc::text(open),
            Doc::indent(Doc::concat(inner)),
            Doc::softline(),
            Doc::text(close)
        ));
    }

    /// The node closing at \p b with \p close had a `,` before it.
    priv fn _trailing_comma(self, b: u32, close: TokenKind) -> bool {
        var l = self._sig_before(b);
        if self._kind_at(l) != close { return false; }
        return self._kind_at(self._sig_before(self.toks[l].start)) == TokenKind::OpComma;
    }

    // ----------------------------------------------------------------------
    //  Lists: statements, members, items, enum variants, match cases
    // ----------------------------------------------------------------------

    priv fn _push_decl(self, d: *Decl, els: *vec::<Elem>) {
        if (d == &null) || d->range.is_invalid() { return; }
        els->push_back(Elem { start: self._decl_start(d), end: d->range.end.raw(), decl: d });
    }

    priv fn _push_stmt(self, s: *Stmt, els: *vec::<Elem>) {
        if (s == &null) || s->range.is_invalid() { return; }
        els->push_back(Elem { start: s->range.start.raw(), end: s->range.end.raw(), stmt: s });
    }

    /// VERIFY: dc_decls's element access, written against ArenaList::get(i) -> *T.
    priv fn _push_dc(self, dc: *DeclContext, els: *vec::<Elem>) {
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            self._push_decl(*(dc->dc_decls.get(i)), els);
        }
    }

    /// Where a decl's text starts: its visibility keyword or first attribute.
    /// Comment annotations are not counted; the token stream owns comments.
    priv fn _decl_start(self, d: *Decl) -> u32 {
        var a = d->range.start.raw();
        if d->has_visibility() {
            var v = d->_visibility_range.start.raw();
            if (v != 0) && (v < a) { a = v; }
        }
        for var i: usize = 0; i < d->annotations.size(); ++i {
            var ae = d->annotations.get(i);
            if ae->kind != AnnotationKind::Attribute { continue; }
            var r = ae->range.start.raw();
            if (r != 0) && (r < a) { a = r; }
        }
        return a;
    }

    priv fn _sort(self, els: *vec::<Elem>) {
        for var i: usize = 1; i < els->size(); ++i {
            var j = i;
            while (j > 0) && ((*els)[j - 1].start > (*els)[j].start) {
                var t = (*els)[j];
                (*els)[j] = (*els)[j - 1];
                (*els)[j - 1] = t;
                j -= 1;
            }
        }
    }

    /// Lays out the elements of the region [lo, hi), with everything between
    /// them: comments, blank lines (rule 3), and code no element covers. \p
    /// opener is the line of the region's `{`, or 0 at file scope.
    priv fn _list(self, lo: u32, hi: u32, opener: usize, els: *vec::<Elem>) -> ListOut {
        self._sort(els);

        var r    = ListOut{};
        var es   = vec::<Entry>();
        var cur  = lo;
        var done = lo;

        for var i: usize = 0; i < els->size(); ++i {
            var el = (*els)[i];

            // a duplicate, or inside something already printed
            if (el.start < done) || (el.end <= el.start) || (el.start < lo) || (el.end > hi) { continue; }

            var st   = el.start;
            var en   = el.end;
            var verb = false;

            // expanded macros: everything they made shares the invocation's range
            var m = self._macro_at(st, en);
            if m < self.ms_lo.size() {
                if self.ms_lo[m] < st { st = self.ms_lo[m]; }
                if self.ms_hi[m] > en { en = self.ms_hi[m]; }
                verb = true;
            }
            if st < cur { continue; }

            self._between(cur, st, opener, &es, &r);

            var e    = Entry{};
            var core = self._core_end(st, en);
            if verb {
                e.doc = Doc::concat2(self._v(st, core), self._semi(self._has_sep(st, en, TokenKind::OpSemicolon)));
            } else {
                self._entry(el, st, en, core, &e);
            }
            e.first = self._line(st);
            e.last  = self._line(en - 1);

            cur = self._skip_seps(en);

            // a comment on the element's last line trails it (rule 4)
            var j = self._lb(cur);
            while (j < self.toks.size()) && (self.toks[j].kind == TokenKind::TkWhitespace) { j += 1; }
            if (j < self.toks.size()) && (self.toks[j].kind == TokenKind::AtComment) {
                var c = self.toks[j];
                if (self._line(c.start) == e.last) && (self._line(c.end - 1) == e.last) && (c.end <= hi) {
                    var s = Doc::line_suffix(Doc::text(" " + self._text(c.start, c.end)));
                    // one line in the source: on its first line whatever it becomes
                    if e.first == e.last { e.doc = Doc::concat2(s, e.doc); }
                    else                 { e.doc = Doc::concat2(e.doc, s); }
                    if e.sep.size() > 0 { e.val = Doc::concat2(e.val, s); }
                    cur = c.end;
                }
            }

            es.push_back(e);
            done = en;
        }

        self._between(cur, hi, opener, &es, &r);
        r.empty = es.empty();
        r.body  = self._layout(&es);
        return r;
    }

    /// Comments and uncovered code in [a, b).
    priv fn _between(self, a: u32, b: u32, opener: usize, es: *vec::<Entry>, r: *ListOut) {
        var n  = self.toks.size();
        var i  = self._lb(a);
        var on = false;
        var g0: u32 = 0;
        var g1: u32 = 0;

        while (i < n) && (self.toks[i].start < b) {
            var t = self.toks[i];
            i += 1;

            if (t.kind == TokenKind::TkNewLine) || (t.kind == TokenKind::TkWhitespace) { continue; }

            if t.kind == TokenKind::AtComment {
                var cl = self._line(t.start);
                var ce = self._line(t.end - 1);

                if on {
                    // on the gap's last line: trails the gap
                    if (cl == self._line(g1 - 1)) && (cl == ce) {
                        self._gap(g0, g1, es, Doc::line_suffix(Doc::text(" " + self._text(t.start, t.end))));
                        on = false;
                        continue;
                    }
                    self._gap(g0, g1, es, Doc::nothing());
                    on = false;
                }

                if es->empty() && (opener != 0) && (cl == opener) && (cl == ce) && r->head.is_empty() {
                    r->head = Doc::line_suffix(Doc::text(" " + self._text(t.start, t.end)));
                    continue;
                }

                var e = Entry{};
                e.doc        = self._v(t.start, t.end);
                e.first      = cl;
                e.last       = ce;
                e.is_comment = true;
                es->push_back(e);
                continue;
            }

            if (!on) && ((t.kind == TokenKind::OpSemicolon) || (t.kind == TokenKind::OpComma)) { continue; }
            if !on {
                g0 = t.start;
                on = true;
            }
            g1 = t.end;
        }

        if on { self._gap(g0, g1, es, Doc::nothing()); }
    }

    priv fn _gap(self, a: u32, b: u32, es: *vec::<Entry>, sfx: Doc) {
        var e = Entry{};
        e.doc   = Doc::concat2(self._v(a, b), sfx);
        e.first = self._line(a);
        e.last  = self._line(b - 1);
        es->push_back(e);
    }

    priv fn _layout(self, es: *vec::<Entry>) -> Doc {
        var parts = vec::<Doc>();
        var n     = es->size();
        var i: usize = 0;

        while i < n {
            if i > 0 {
                parts.push_back(Doc::hardline());
                var prev = (*es)[i - 1].last;
                var next = (*es)[i].first;
                if next > (prev + 1) {
                    var blank = next - prev - 1;
                    if blank > Formatter::max_blank_lines() { blank = Formatter::max_blank_lines(); }
                    for var b: usize = 0; b < blank; ++b { parts.push_back(Doc::hardline()); }
                }
            }

            var j = self._run(es, i);
            if j > (i + 1) {
                var rows = vec::<Doc>();
                var seps = vec::<string>();
                for var k = i; k < j; ++k {
                    rows.push_back((*es)[k].key);
                    rows.push_back((*es)[k].val);
                    seps.push_back((*es)[k].sep);
                }
                parts.push_back(Doc::align(rows, seps));
                i = j;
                continue;
            }

            parts.push_back((*es)[i].doc);
            i += 1;
        }

        return Doc::concat(parts);
    }

    /// Rule 2: past the end of the alignment run starting at \p i. A run is
    /// one-line rows with the same sep on consecutive source lines, each of
    /// which fits flat.
    priv fn _run(self, es: *vec::<Entry>, i: usize) -> usize {
        var n   = es->size();
        var sep = (*es)[i].sep;
        if sep.size() == 0 { return i; }

        var room = Formatter::line_width() - (self._depth * indent_width());
        var j    = i;
        while j < n {
            var e = (*es)[j];
            if e.is_comment || (e.sep != sep) || (e.first != e.last) { break; }
            if (j > i) && (e.first != ((*es)[j - 1].last + 1)) { break; }

            var w = Renderer::flat_width(&e.key) + static_cast::<i32>(sep.length()) + Renderer::flat_width(&e.val);
            if w > room { break; }
            j += 1;
        }
        return j;
    }

    priv fn _entry(self, el: Elem, st: u32, en: u32, core: u32, e: *Entry) {
        var semi = self._semi(self._has_sep(st, en, TokenKind::OpSemicolon));

        if el.decl != &null {
            e->doc = self._decl(el.decl, st, core, semi, e);
            return;
        }
        if el.stmt != &null {
            e->doc = self._stmt(el.stmt, st, core, semi, e);
            return;
        }
        if el.expr != &null {
            e->doc = Doc::concat2(self.fx(el.expr, true), semi);
            return;
        }
        if el.variant != &null {
            var comma = (Doc::text(",")) if (self._has_sep(st, en, TokenKind::OpComma)) else (Doc::nothing());
            e->doc = self._variant(el.variant, st, core, comma, e);
            return;
        }
        if el.mcase != &null {
            e->doc = self._case(el.mcase, st, core, semi);
            return;
        }
        e->doc = Doc::concat2(self._v(st, core), semi);
    }

    // ----------------------------------------------------------------------
    //  Blocks
    // ----------------------------------------------------------------------

    /// `{ ... }`. A block written on one line holding one simple statement
    /// stays on one line while it fits.
    priv fn _block(self, b: *CompoundStmt) -> Doc {
        var a = b->range.start.raw();
        var z = b->range.end.raw();
        var o = self._sig_after(a);
        var c = self._sig_before(z);
        if (self._kind_at(o) != TokenKind::OpLBrace) || (self._kind_at(c) != TokenKind::OpRBrace) || (o >= c) {
            return self._v(a, z);
        }

        var lo = self.toks[o].end;
        var hi = self.toks[c].start;

        if b->body.is_empty() && (!self._comment_in(lo, hi)) && (!self._has_sig(lo, hi)) {
            return Doc::text("{ }");
        }

        if (self._line(a) == self._line(z - 1)) && (b->body.size() == 1)
        && (!self._comment_in(lo, hi)) && (!self._is_block_stmt(b->body[0])) {
            var s0 = b->body[0];
            var sa = s0->range.start.raw();
            var se = s0->range.end.raw();
            var sd = self._stmt(s0, sa, self._core_end(sa, se), self._semi(self._has_sep(sa, se, TokenKind::OpSemicolon)), &null);
            return Doc::group(Doc::concat3(
                Doc::text("{"),
                Doc::indent(Doc::concat2(Doc::line(), sd)),
                Doc::concat2(Doc::line(), Doc::text("}"))
            ));
        }

        var els = vec::<Elem>();
        for var i: usize = 0; i < b->body.size(); ++i { self._push_stmt(b->body[i], &els); }
        return self._braced(Doc::nothing(), lo, hi, self._line(self.toks[o].start), &els);
    }

    /// \p head ` {` members `}`.
    priv fn _braced(self, head: Doc, lo: u32, hi: u32, opener: usize, els: *vec::<Elem>) -> Doc {
        self._depth += 1;
        var l = self._list(lo, hi, opener, els);
        self._depth -= 1;

        var open = (Doc::text("{")) if (head.is_empty()) else (Doc::concat2(head, Doc::text(" {")));
        if l.empty && l.head.is_empty() {
            return Doc::concat2(open, Doc::text(" }"));
        }
        return Doc::concat5(
            open,
            l.head,
            Doc::indent(Doc::concat2(Doc::hardline(), l.body)),
            Doc::hardline(),
            Doc::text("}")
        );
    }

    /// Header as written, then a formatted block.
    priv fn _hb(self, a: u32, blk: *CompoundStmt) -> Doc {
        if blk == &null { return Doc::nothing(); }
        var h = self._span(a, blk->range.start.raw());
        if h.is_empty() { return self._block(blk); }
        return Doc::concat3(h, Doc::text(" "), self._block(blk));
    }

    priv fn _is_block_stmt(self, s: *Stmt) -> bool {
        if s == &null { return false; }
        if isa::<DeclStmt>(s) {
            var d = cast::<DeclStmt>(s)->decl;
            return (d != &null) && (!isa::<VariableDecl>(d));
        }
        return isa::<CompoundStmt>(s)  || isa::<ConditionalStmt>(s) || isa::<WhileLoopStmt>(s)
            || isa::<LoopStmt>(s)      || isa::<RangedForStmt>(s)   || isa::<IndexedForStmt>(s)
            || isa::<MatchStmt>(s)     || isa::<LabeledStmt>(s)     || isa::<TryCatchStmt>(s)
            || isa::<FinallyStmt>(s)   || isa::<UnsafeBlockStmt>(s) || isa::<ContextBindingStmt>(s);
    }

    // ----------------------------------------------------------------------
    //  Statements
    // ----------------------------------------------------------------------

    /// \p e, when given, is filled for alignment (rule 2).
    priv fn _stmt(self, s: *Stmt, st: u32, en: u32, semi: Doc, e: *Entry) -> Doc {
        if isa::<CompoundStmt>(s) { return Doc::concat2(self._block(cast::<CompoundStmt>(s)), semi); }

        if isa::<ExpressionStmt>(s) {
            var x = cast::<ExpressionStmt>(s)->expr;
            if (e != &null) && (x != &null) && isa::<AssignOperatorExpr>(x)
            && (!self._comment_in(st, en)) && (!self._macro_in(st, en)) && (!self._wrapped(x)) {
                var a = cast::<AssignOperatorExpr>(x);
                if self._tok(a->op_token) == "=" {
                    e->key = self.fx(a->lhs, true);
                    e->sep = " = ";
                    e->val = Doc::concat2(self.fx(a->rhs, true), semi);
                    return Doc::concat3(e->key, Doc::text(" = "), e->val);
                }
            }
            return Doc::concat2(self.fx(x, true), semi);
        }

        if isa::<DeclStmt>(s) { return self._decl(cast::<DeclStmt>(s)->decl, st, en, semi, e); }

        if isa::<ReturnStmt>(s) {
            var v = cast::<ReturnStmt>(s)->value;
            if v == &null { return Doc::concat2(Doc::text("return"), semi); }
            return Doc::concat3(Doc::text("return "), self.fx(v, true), semi);
        }

        if isa::<BreakStmt>(s) {
            var b = cast::<BreakStmt>(s);
            if !b->has_label { return Doc::concat2(Doc::text("break"), semi); }
            return Doc::concat2(Doc::text("break " + self._tok(b->label)), semi);
        }

        if isa::<ContinueStmt>(s) {
            var c = cast::<ContinueStmt>(s);
            if !c->has_label { return Doc::concat2(Doc::text("continue"), semi); }
            return Doc::concat2(Doc::text("continue " + self._tok(c->label)), semi);
        }

        if isa::<PanicStmt>(s) { return Doc::concat3(Doc::text("panic "), self.fx(cast::<PanicStmt>(s)->payload, true), semi); }
        if isa::<YieldStmt>(s) { return Doc::concat3(Doc::text("yield "), self.fx(cast::<YieldStmt>(s)->value, true), semi); }

        if isa::<ConditionalStmt>(s) { return Doc::concat2(self._if(cast::<ConditionalStmt>(s), st, en), semi); }

        if isa::<WhileLoopStmt>(s)      { return Doc::concat2(self._hb(st, cast::<WhileLoopStmt>(s)->body), semi); }
        if isa::<LoopStmt>(s)           { return Doc::concat2(self._hb(st, cast::<LoopStmt>(s)->body), semi); }
        if isa::<RangedForStmt>(s)      { return Doc::concat2(self._hb(st, cast::<RangedForStmt>(s)->body), semi); }
        if isa::<IndexedForStmt>(s)     { return Doc::concat2(self._hb(st, cast::<IndexedForStmt>(s)->body), semi); }
        if isa::<FinallyStmt>(s)        { return Doc::concat2(self._hb(st, cast::<FinallyStmt>(s)->body), semi); }
        if isa::<UnsafeBlockStmt>(s)    { return Doc::concat2(self._hb(st, cast::<UnsafeBlockStmt>(s)->body), semi); }
        if isa::<ContextBindingStmt>(s) { return Doc::concat2(self._hb(st, cast::<ContextBindingStmt>(s)->body), semi); }

        if isa::<MatchStmt>(s)    { return self._match(cast::<MatchStmt>(s), st, en, semi); }
        if isa::<TryCatchStmt>(s) { return Doc::concat2(self._try(cast::<TryCatchStmt>(s), st, en), semi); }

        if isa::<LabeledStmt>(s) {
            var l  = cast::<LabeledStmt>(s);
            var _in = l->inner;
            if _in == &null { return Doc::concat2(self._v(st, en), semi); }
            var ia = _in->range.start.raw();
            var ie = _in->range.end.raw();
            return Doc::concat3(
                Doc::text(self._tok(l->label) + ": "),
                self._stmt(_in, ia, self._core_end(ia, ie), Doc::nothing(), &null),
                semi
            );
        }

        if isa::<DestructuringDeclStmt>(s) {
            var v = cast::<DestructuringDeclStmt>(s)->value;
            if (v == &null) || self._comment_in(st, v->range.start.raw()) { return Doc::concat2(self._v(st, en), semi); }
            return Doc::concat4(self._span(st, v->range.start.raw()), Doc::text(" "), self.fx(v, true), semi);
        }

        // asserts, label!/jump!, inline blocks (copied exactly), eval blocks, the rest
        return Doc::concat2(self._v(st, en), semi);
    }

    /// `if`/`else if`/`else` chain. Each header is copied from the end of the
    /// previous block, so `else`, `else if` and `eval` stay as written.
    priv fn _if(self, s: *ConditionalStmt, st: u32, en: u32) -> Doc {
        if s->then_ == &null { return self._v(st, en); }

        var d   = self._hb(st, s->then_);
        var cur = s;
        while cur->else_ != &null {
            var prev = cur->then_->range.end.raw();
            var el   = cur->else_;

            if isa::<ConditionalStmt>(el) {
                var ec = cast::<ConditionalStmt>(el);
                if ec->then_ == &null { return self._v(st, en); }
                d   = Doc::concat3(d, Doc::text(" "), self._hb(prev, ec->then_));
                cur = ec;
                continue;
            }

            if isa::<CompoundStmt>(el) {
                d = Doc::concat3(d, Doc::text(" "), self._hb(prev, cast::<CompoundStmt>(el)));
                break;
            }

            return self._v(st, en);
        }
        return d;
    }

    priv fn _try(self, s: *TryCatchStmt, st: u32, en: u32) -> Doc {
        if s->try_body == &null { return self._v(st, en); }

        var d    = self._hb(st, s->try_body);
        var prev = s->try_body->range.end.raw();
        for var i: usize = 0; i < s->arms.size(); ++i {
            var arm = s->arms.get(i);
            if arm->body == &null { return self._v(st, en); }
            d    = Doc::concat3(d, Doc::text(" "), self._hb(prev, arm->body));
            prev = arm->body->range.end.raw();
        }
        return d;
    }

    priv fn _match(self, s: *MatchStmt, st: u32, en: u32, semi: Doc) -> Doc {
        if s->scrutinee == &null { return Doc::concat2(self._v(st, en), semi); }

        var o = self._sig_after(s->scrutinee->range.end.raw());
        var c = self._sig_before(en);
        if (self._kind_at(o) != TokenKind::OpLBrace) || (self._kind_at(c) != TokenKind::OpRBrace) || (o >= c) {
            return Doc::concat2(self._v(st, en), semi);
        }

        var els = vec::<Elem>();
        for var i: usize = 0; i < s->cases.size(); ++i {
            var mc = s->cases.get(i);
            if mc->range.is_invalid() { continue; }
            els.push_back(Elem { start: mc->range.start.raw(), end: mc->range.end.raw(), mcase: mc });
        }

        var head = self._span(st, self.toks[o].start);
        return Doc::concat2(
            self._braced(head, self.toks[o].end, self.toks[c].start, self._line(self.toks[o].start), &els),
            semi
        );
    }

    priv fn _case(self, mc: *MatchCase, st: u32, en: u32, semi: Doc) -> Doc {
        if mc->body == &null { return Doc::concat2(self._v(st, en), semi); }
        return Doc::concat2(self._hb(st, mc->body), semi);
    }

    // ----------------------------------------------------------------------
    //  Declarations
    // ----------------------------------------------------------------------

    priv fn _decl(self, d: *Decl, st: u32, en: u32, semi: Doc, e: *Entry) -> Doc {
        if d == &null { return Doc::concat2(self._v(st, en), semi); }

        if isa::<VariableDecl>(d) {
            var v = cast::<VariableDecl>(d);
            return self._var(st, en, v->type_, v->init, semi, e);
        }
        if isa::<FieldDecl>(d) {
            var f = cast::<FieldDecl>(d);
            return self._var(st, en, f->type_, f->init, semi, e);
        }
        if isa::<FunctionDecl>(d) { return self._fn(cast::<FunctionDecl>(d), st, en, semi); }

        if isa::<TestDecl>(d) {
            var t = cast::<TestDecl>(d);
            if t->body == &null { return Doc::concat2(self._v(st, en), semi); }
            return Doc::concat2(self._hb(st, t->body), semi);
        }
        if isa::<ProcedureMacroDecl>(d) {
            var p = cast::<ProcedureMacroDecl>(d);
            if p->body == &null { return Doc::concat2(self._v(st, en), semi); }
            return Doc::concat2(self._hb(st, p->body), semi);
        }

        var els = vec::<Elem>();
        if isa::<ClassDecl>(d) {
            var c = cast::<ClassDecl>(d);
            for var i: usize = 0; i < c->fields.size(); ++i  { self._push_decl(c->fields[i], &els); }
            for var i: usize = 0; i < c->methods.size(); ++i { self._push_decl(c->methods[i], &els); }
            self._push_dc(static_cast::<*DeclContext>(c), &els);
            return self._aggregate(st, en, semi, &els);
        }
        if isa::<StructDecl>(d) {
            var s = cast::<StructDecl>(d);
            for var i: usize = 0; i < s->fields.size(); ++i  { self._push_decl(s->fields[i], &els); }
            for var i: usize = 0; i < s->methods.size(); ++i { self._push_decl(s->methods[i], &els); }
            self._push_dc(static_cast::<*DeclContext>(s), &els);
            return self._aggregate(st, en, semi, &els);
        }
        if isa::<UnionDecl>(d) {
            var u = cast::<UnionDecl>(d);
            for var i: usize = 0; i < u->fields.size(); ++i  { self._push_decl(u->fields[i], &els); }
            for var i: usize = 0; i < u->methods.size(); ++i { self._push_decl(u->methods[i], &els); }
            self._push_dc(static_cast::<*DeclContext>(u), &els);
            return self._aggregate(st, en, semi, &els);
        }
        if isa::<InterfaceDecl>(d) {
            var it = cast::<InterfaceDecl>(d);
            for var i: usize = 0; i < it->methods.size(); ++i { self._push_decl(it->methods[i], &els); }
            self._push_dc(static_cast::<*DeclContext>(it), &els);
            return self._aggregate(st, en, semi, &els);
        }
        if isa::<ExtensionDecl>(d) {
            var x = cast::<ExtensionDecl>(d);
            for var i: usize = 0; i < x->methods.size(); ++i { self._push_decl(x->methods[i], &els); }
            self._push_dc(static_cast::<*DeclContext>(x), &els);
            return self._aggregate(st, en, semi, &els);
        }
        if isa::<EnumDecl>(d) {
            var en_ = cast::<EnumDecl>(d);
            for var i: usize = 0; i < en_->variants.size(); ++i {
                var v = en_->variants[i];
                if (v == &null) || v->range.is_invalid() { continue; }
                els.push_back(Elem { start: self._decl_start(v), end: v->range.end.raw(), variant: v });
            }
            self._push_dc(static_cast::<*DeclContext>(en_), &els);
            return self._aggregate(st, en, semi, &els);
        }
        if isa::<ModuleDecl>(d) {
            self._push_dc(static_cast::<*DeclContext>(cast::<ModuleDecl>(d)), &els);
            return self._aggregate(st, en, semi, &els);
        }
        if isa::<VisibilityGroupDecl>(d) {
            var g = cast::<VisibilityGroupDecl>(d);
            for var i: usize = 0; i < g->members.size(); ++i { self._push_decl(g->members[i], &els); }
            return self._aggregate(st, en, semi, &els);
        }
        if isa::<FFIBlockDecl>(d) {
            var fb = cast::<FFIBlockDecl>(d);
            for var i: usize = 0; i < fb->body.size(); ++i { self._push_decl(fb->body[i], &els); }
            return self._aggregate(st, en, semi, &els);
        }

        // imports, type aliases, macro decls, eval blocks: as written
        return Doc::concat2(self._v(st, en), semi);
    }

    /// `var`/`const`/field. Rule 2 keys: everything before the `:` or `=`.
    priv fn _var(self, st: u32, en: u32, ty: *Type, init: *Expr, semi: Doc, e: *Entry) -> Doc {
        if self._comment_in(st, en) || ((ty == &null) && (init == &null)) {
            return Doc::concat2(self._v(st, en), semi);
        }

        var pe = (ty->range.start.raw()) if (ty != &null) else (init->range.start.raw());
        var k  = self._sig_before(pe);
        var want = (TokenKind::OpColon) if (ty != &null) else (TokenKind::OpEqual);
        if self._kind_at(k) != want { return Doc::concat2(self._v(st, en), semi); }

        var key = self._span(st, self.toks[k].start);
        if key.is_empty() { return Doc::concat2(self._v(st, en), semi); }

        if ty != &null {
            var val = self._v(ty->range.start.raw(), ty->range.end.raw());
            if init != &null {
                var eq = self._sig_after(ty->range.end.raw());
                if (self._kind_at(eq) != TokenKind::OpEqual) || (self._sig_after(self.toks[eq].end) != self._sig_after(init->range.start.raw())) {
                    return Doc::concat2(self._v(st, en), semi);
                }
                val = Doc::concat3(val, Doc::text(" = "), self.fx(init, true));
            }
            val = Doc::concat2(val, semi);
            if e != &null {
                e->key = key;
                e->sep = " : ";
                e->val = val;
            }
            return Doc::concat3(key, Doc::text(": "), val);
        }

        var v = Doc::concat2(self.fx(init, true), semi);
        if e != &null {
            e->key = key;
            e->sep = " = ";
            e->val = v;
        }
        return Doc::concat3(key, Doc::text(" = "), v);
    }

    /// Header as written, the parameter list under rule 1, body formatted.
    priv fn _fn(self, f: *FunctionDecl, st: u32, en: u32, semi: Doc) -> Doc {
        var be = en;
        if (f->body_kind == FnBodyKind::Block) && (f->body_block != &null) { be = f->body_block->range.start.raw(); }
        if (f->body_kind == FnBodyKind::Expr)  && (f->body_expr  != &null) { be = f->body_expr->range.start.raw(); }

        var hd = self._fn_head(f, st, be);

        if (f->body_kind == FnBodyKind::Block) && (f->body_block != &null) {
            return Doc::concat4(hd, Doc::text(" "), self._block(f->body_block), semi);
        }
        if (f->body_kind == FnBodyKind::Expr) && (f->body_expr != &null) {
            return Doc::concat4(hd, Doc::text(" "), self.fx(f->body_expr, true), semi);
        }
        return Doc::concat2(hd, semi);
    }

    priv fn _fn_head(self, f: *FunctionDecl, st: u32, be: u32) -> Doc {
        if f->is_operator || f->params.is_empty() || f->params_end.is_invalid()
        || self._comment_in(st, be) || self._macro_in(st, be) {
            return self._span(st, be);
        }

        var p0 = f->params[0];
        if (p0 == &null) || p0->range.is_invalid() { return self._span(st, be); }

        var o = self._sig_before(p0->range.start.raw());
        if self._kind_at(o) != TokenKind::OpLParen { return self._span(st, be); }

        var items = vec::<Doc>();
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if (p == &null) || p->range.is_invalid() { return self._span(st, be); }
            items.push_back(self._v(p->range.start.raw(), p->range.end.raw()));
        }

        var pe    = f->params_end.start.raw();
        var trail = self._kind_at(self._sig_before(pe)) == TokenKind::OpComma;
        var hd    = Doc::concat2(self._span(st, self.toks[o].start), self._seq("(", items, ")", trail));

        var tail = self._span(f->params_end.end.raw(), be);
        if tail.is_empty() { return hd; }
        return Doc::concat3(hd, Doc::text(" "), tail);
    }

    /// class/struct/union/interface/extend/enum/module/`pub { }`/ffi block.
    priv fn _aggregate(self, st: u32, en: u32, semi: Doc, els: *vec::<Elem>) -> Doc {
        var n = self.toks.size();
        var o = n;
        var depth: i32 = 0;
        for var i = self._lb(st); i < n; ++i {
            var t = self.toks[i];
            if t.start >= en { break; }
            if (t.kind == TokenKind::OpLParen) || (t.kind == TokenKind::OpLSquare) { depth += 1; }
            if (t.kind == TokenKind::OpRParen) || (t.kind == TokenKind::OpRSquare) { depth -= 1; }
            if (t.kind == TokenKind::OpLBrace) && (depth == 0) {
                o = i;
                break;
            }
        }

        var c = self._sig_before(en);
        if (o >= n) || (self._kind_at(c) != TokenKind::OpRBrace) || (o >= c) {
            return Doc::concat2(self._v(st, en), semi);   // forward declaration
        }

        var head = self._span(st, self.toks[o].start);
        return Doc::concat2(
            self._braced(head, self.toks[o].end, self.toks[c].start, self._line(self.toks[o].start), els),
            semi
        );
    }

    priv fn _variant(self, v: *EnumVariantDecl, st: u32, en: u32, comma: Doc, e: *Entry) -> Doc {
        var d = v->discriminant;
        if (d != &null) && v->payload.is_empty() && (!self._comment_in(st, en)) {
            var eq = self._sig_before(d->range.start.raw());
            if self._kind_at(eq) == TokenKind::OpEqual {
                var key = self._span(st, self.toks[eq].start);
                var val = Doc::concat2(self._v(d->range.start.raw(), d->range.end.raw()), comma);
                e->key = key;
                e->sep = " = ";
                e->val = val;
                return Doc::concat3(key, Doc::text(" = "), val);
            }
        }
        return Doc::concat2(self._v(st, en), comma);
    }

    // ----------------------------------------------------------------------
    //  Expressions
    // ----------------------------------------------------------------------

    /// \p e with the parentheses the source had around it. Semantic parses
    /// fold parens away, so they come back from the tokens: a pair inside the
    /// node's own range, and, at operand positions (\p ext), pairs glued
    /// around it.
    fn fx(self, e: *Expr, ext: bool) -> Doc {
        if e == &null { return Doc::nothing(); }

        var d = self._expr(e);
        var n: u32 = 0;
        if self._int_parens(e) { n += 1; }
        if ext { n += self._ext_parens(e->range.start.raw(), e->range.end.raw()); }

        for var i: u32 = 0; i < n; ++i {
            d = Doc::concat3(Doc::text("("), d, Doc::text(")"));
        }
        return d;
    }

    priv fn _wrapped(self, e: *Expr) -> bool {
        return self._int_parens(e) || (self._ext_parens(e->range.start.raw(), e->range.end.raw()) > 0);
    }

    priv fn _ext_parens(self, a: u32, b: u32) -> u32 {
        var n: u32 = 0;
        var i = self._sig_before(a);
        var j = self._sig_after(b);
        while (self._kind_at(i) == TokenKind::OpLParen) && (self._kind_at(j) == TokenKind::OpRParen) {
            n += 1;
            i = self._sig_before(self.toks[i].start);
            j = self._sig_after(self.toks[j].end);
        }
        return n;
    }

    /// The node's own range is one parenthesized whole: `(a + b)`.
    priv fn _int_parens(self, e: *Expr) -> bool {
        if isa::<TupleLiteralExpr>(e) || isa::<ParenExpr>(e) { return false; }

        var f = self._sig_after(e->range.start.raw());
        var l = self._sig_before(e->range.end.raw());
        if (f >= l) || (l >= self.toks.size()) { return false; }
        if (self.toks[f].kind != TokenKind::OpLParen) || (self.toks[l].kind != TokenKind::OpRParen) { return false; }

        var depth: i32 = 0;
        for var i = f; i <= l; ++i {
            var k = self.toks[i].kind;
            if k == TokenKind::OpLParen { depth += 1; }
            if k == TokenKind::OpRParen {
                depth -= 1;
                if (depth == 0) && (i < l) { return false; }
            }
        }
        return true;
    }

    /// \p e as written, minus a parenthesized range's own pair (fx adds it).
    priv fn _ev(self, e: *Expr) -> Doc {
        var a = e->range.start.raw();
        var b = e->range.end.raw();
        if self._int_parens(e) {
            return self._span(self.toks[self._sig_after(a)].end, self.toks[self._sig_before(b)].start);
        }
        return self._v(a, b);
    }

    priv fn _expr(self, e: *Expr) -> Doc {
        var a = e->range.start.raw();
        var b = e->range.end.raw();

        if e->is_error() || e->range.is_invalid() { return self._ev(e); }
        if self._comment_in(a, b) || self._macro_in(a, b) { return self._ev(e); }

        if isa::<ChainExpr>(e)          { return self._chain(cast::<ChainExpr>(e)); }
        if isa::<CallExpr>(e)           { return self._call(cast::<CallExpr>(e)); }
        if isa::<BinaryOperatorExpr>(e) { return self._binary(cast::<BinaryOperatorExpr>(e)); }

        if isa::<NamedArgExpr>(e) {
            var na = cast::<NamedArgExpr>(e);
            return Doc::concat2(Doc::text(self._tok(na->name) + ": "), self.fx(na->value, false));
        }

        if isa::<SubscriptExpr>(e) {
            var s = cast::<SubscriptExpr>(e);
            return Doc::concat4(self.fx(s->base, true), Doc::text("["), self.fx(s->index, false), Doc::text("]"));
        }

        if isa::<ListLiteralExpr>(e) {
            var l = cast::<ListLiteralExpr>(e);
            var xs = vec::<Doc>();
            for var i: usize = 0; i < l->elements.size(); ++i { xs.push_back(self.fx(l->elements[i], false)); }
            return self._seq("[", xs, "]", self._trailing_comma(b, TokenKind::OpRSquare));
        }

        if isa::<TupleLiteralExpr>(e) {
            var t = cast::<TupleLiteralExpr>(e);
            var xs = vec::<Doc>();
            for var i: usize = 0; i < t->elements.size(); ++i { xs.push_back(self.fx(t->elements[i], false)); }
            return self._seq("(", xs, ")", self._trailing_comma(b, TokenKind::OpRParen));
        }

        if isa::<NamedInitializerExpr>(e) {
            var ni = cast::<NamedInitializerExpr>(e);
            if ni->is_dotted || (ni->type_expr == &null) || ni->fields.is_empty() { return self._ev(e); }

            var xs = vec::<Doc>();
            for var i: usize = 0; i < ni->fields.size(); ++i {
                var f = ni->fields.get(i);
                xs.push_back(Doc::concat2(Doc::text(self._tok(f->name) + ": "), self.fx(f->value, false)));
            }
            var inner = Doc::join(xs, Doc::concat2(Doc::text(","), Doc::line()));
            if self._trailing_comma(b, TokenKind::OpRBrace) { inner = Doc::concat2(inner, Doc::text(",")); }

            return Doc::concat3(
                self.fx(ni->type_expr, true),
                Doc::text(" "),
                Doc::group(Doc::concat4(
                    Doc::text("{"),
                    Doc::indent(Doc::concat2(Doc::line(), inner)),
                    Doc::line(),
                    Doc::text("}")
                ))
            );
        }

        if isa::<UnaryOperatorExpr>(e) {
            var u  = cast::<UnaryOperatorExpr>(e);
            var _op = self._tok(u->op_token);
            if u->is_postfix() { return Doc::concat2(self.fx(u->operand, true), Doc::text(_op)); }

            // word operators (`not`) need their space back
            var word = (_op.size() > 0) && (((_op[0] >= 'a') && (_op[0] <= 'z')) || ((_op[0] >= 'A') && (_op[0] <= 'Z')));
            if word { _op += " "; }
            return Doc::concat2(Doc::text(_op), self.fx(u->operand, true));
        }

        if isa::<AssignOperatorExpr>(e) {
            var x = cast::<AssignOperatorExpr>(e);
            return Doc::concat3(self.fx(x->lhs, true), Doc::text(" " + self._tok(x->op_token) + " "), self.fx(x->rhs, true));
        }

        if isa::<RangeExpr>(e) {
            var r = cast::<RangeExpr>(e);
            var _op = ("..=") if (r->is_inclusive) else ("..");
            return Doc::concat3(self.fx(r->begin, true), Doc::text(_op), self.fx(r->end, true));
        }

        if isa::<TypeCastExpr>(e) {
            var c = cast::<TypeCastExpr>(e);
            if (c->mode != CastMode::Default) || (c->target == &null) { return self._ev(e); }
            return Doc::concat3(
                self.fx(c->operand, true),
                Doc::text(" as "),
                self._v(c->target->range.start.raw(), c->target->range.end.raw())
            );
        }

        if isa::<IfExpr>(e) { return self._ternary(cast::<IfExpr>(e)); }

        if isa::<AwaitExpr>(e)  { return Doc::concat2(Doc::text("await "),  self.fx(cast::<AwaitExpr>(e)->operand, true)); }
        if isa::<SpawnExpr>(e)  { return Doc::concat2(Doc::text("spawn "),  self.fx(cast::<SpawnExpr>(e)->operand, true)); }
        if isa::<ThreadExpr>(e) { return Doc::concat2(Doc::text("thread "), self.fx(cast::<ThreadExpr>(e)->operand, true)); }
        if isa::<EvalExpr>(e)   { return Doc::concat2(Doc::text("eval "),   self.fx(cast::<EvalExpr>(e)->operand, true)); }
        if isa::<UnsafeExpr>(e) { return Doc::concat2(Doc::text("unsafe "), self.fx(cast::<UnsafeExpr>(e)->operand, true)); }

        if isa::<PackExpansionExpr>(e) { return Doc::concat2(self.fx(cast::<PackExpansionExpr>(e)->operand, true), Doc::text("...")); }

        if isa::<ParenExpr>(e) {
            return Doc::concat3(Doc::text("("), self.fx(cast::<ParenExpr>(e)->inner, false), Doc::text(")"));
        }

        if isa::<ConstraintExpr>(e) {
            var c = cast::<ConstraintExpr>(e);
            if c->rhs == &null { return self._ev(e); }
            return Doc::concat3(
                self.fx(c->lhs, true),
                Doc::text(" " + self._tok(c->op_token) + " "),
                self._v(c->rhs->range.start.raw(), c->rhs->range.end.raw())
            );
        }

        // literals, names, closures, initializers with no head, sizeof/typeof,
        // unwrap!/defined!, attributes, try/match expressions, the rest
        return self._ev(e);
    }

    priv fn _chain(self, c: *ChainExpr) -> Doc {
        if c->has_generic_args() { return self._ev(c); }

        var parts = vec::<Doc>();
        if c->base != &null { parts.push_back(self.fx(c->base, true)); }

        for var i: usize = 0; i < c->steps.size(); ++i {
            var s = c->steps.get(i);
            if s->is_operator() { return self._ev(c); }

            switch s->access_kind {
                case ChainExpr::AccessKind::Dot           { parts.push_back(Doc::text(".")); }
                case ChainExpr::AccessKind::Arrow         { parts.push_back(Doc::text("->")); }
                case ChainExpr::AccessKind::ColonColon    { parts.push_back(Doc::text("::")); }
                case ChainExpr::AccessKind::QuestionDot   { parts.push_back(Doc::text("?.")); }
                case ChainExpr::AccessKind::QuestionArrow { parts.push_back(Doc::text("?->")); }
            }

            if s->is_tuple_index() {
                parts.push_back(Doc::text(f"{s->index}"));
            } else if s->name != &null {
                parts.push_back(Doc::text(self._tok(s->name->name)));
            } else {
                return self._ev(c);
            }
        }
        return Doc::concat(parts);
    }

    priv fn _call(self, c: *CallExpr) -> Doc {
        if c->callee == &null { return self._ev(c); }

        var xs = vec::<Doc>();
        for var i: usize = 0; i < c->args.size(); ++i { xs.push_back(self.fx(c->args[i], false)); }
        var trail = (!c->args.is_empty()) && self._trailing_comma(c->range.end.raw(), TokenKind::OpRParen);
        return Doc::concat2(self.fx(c->callee, true), self._seq("(", xs, ")", trail));
    }

    priv fn _binary(self, b: *BinaryOperatorExpr) -> Doc {
        var k  = b->op_token.kind;
        var _op = self._tok(b->op_token);

        // `<` / `>` / `>>` glued to a neighbour: maybe a generic the parser
        // read as comparisons (sema turns those into calls). As written, so
        // a misparse can never gain spaces.
        if (k == TokenKind::OpLess) || (k == TokenKind::OpGreater) || (k == TokenKind::OpGreaterGreater) {
            var os = b->op_token.range.start.raw();
            var oe = b->op_token.range.end.raw();
            var pv = self._sig_before(os);
            var nx = self._sig_after(oe);
            var glued = ((pv < self.toks.size()) && (self.toks[pv].end == os))
                     || ((nx < self.toks.size()) && (self.toks[nx].start == oe));
            if glued { return self._ev(b); }
        }

        if (k == TokenKind::OpAmpAmp) || (k == TokenKind::OpPipePipe) {
            var xs  = vec::<*Expr>();
            var ops = vec::<string>();
            self._flatten(b->lhs, k, &xs, &ops);
            ops.push_back(_op);
            self._flatten(b->rhs, k, &xs, &ops);

            var tail = vec::<Doc>();
            for var i: usize = 1; i < xs.size(); ++i {
                tail.push_back(Doc::line());
                tail.push_back(Doc::text(ops[i - 1] + " "));
                tail.push_back(self.fx(xs[i], true));
            }
            return Doc::group(Doc::concat2(self.fx(xs[0], true), Doc::indent(Doc::concat(tail))));
        }

        if (_op == ".*") || (_op == "->*") || (_op == "?.*") || (_op == "?->*") {
            return Doc::concat3(self.fx(b->lhs, true), Doc::text(_op), self.fx(b->rhs, true));
        }
        return Doc::concat3(self.fx(b->lhs, true), Doc::text(" " + _op + " "), self.fx(b->rhs, true));
    }

    /// Operands of a run of one logical operator, unparenthesized ones only.
    priv fn _flatten(self, e: *Expr, k: TokenKind, xs: *vec::<*Expr>, ops: *vec::<string>) {
        var b = dyn_cast::<BinaryOperatorExpr>(e);
        if (b != &null) && (b->op_token.kind == k) && (!self._wrapped(e))
        && (!self._comment_in(e->range.start.raw(), e->range.end.raw()))
        && (!self._macro_in(e->range.start.raw(), e->range.end.raw())) {
            self._flatten(b->lhs, k, xs, ops);
            ops->push_back(self._tok(b->op_token));
            self._flatten(b->rhs, k, xs, ops);
            return;
        }
        xs->push_back(e);
    }

    /// `a if c else b`. The block form and `else if` chains are copied as written.
    priv fn _ternary(self, x: *IfExpr) -> Doc {
        var f = self._sig_after(x->range.start.raw());
        if (self._kind_at(f) == TokenKind::KwIf) || (!x->else_ifs.is_empty())
        || (x->then_expr == &null) || (x->condition == &null) || (x->else_expr == &null) {
            return self._ev(x);
        }
        return Doc::group(Doc::concat2(
            self.fx(x->then_expr, true),
            Doc::indent(Doc::concat4(
                Doc::concat2(Doc::line(), Doc::text("if ")),
                self.fx(x->condition, true),
                Doc::concat2(Doc::line(), Doc::text("else ")),
                self.fx(x->else_expr, true)
            ))
        ));
    }
}

/// ----------------------------------------------------------------------
/// DRIVER
/// ----------------------------------------------------------------------

/// One file through the preprocessor and parser alone: no dependency scan,
/// no import graph. Imports stay unresolved, which formatting never needs,
/// and a module whose files import each other (builtin) formats file by file.
fn parse_alone(ci: *CompilerInstance, name: string) -> ParsedUnit {
    var fid = load(ci, Path(name));
    if fid == u32(-1) { return ParsedUnit::failure(fid, TUStage::Failed); }

    var u = ParsedUnit{};
    u.fid = fid;
    u.fids.push_back(fid);

    var err0 = ci->diag()->error_count();
    var wrn0 = ci->diag()->warn_count();

    var collector = std::create::<ToolDiagConsumer>(ci->sm());
    var saved     = ci->diag()->take_consumers();
    ci->diag()->add_consumer(collector);
    finally {
        ci->diag()->restore_consumers(saved);
        std::destroy(collector);
    }

    u.stage = TUStage::Preprocessing;
    if ci->pp()->preprocess_one(fid, ModulePath()) {
        u.ctx = ci->global_scope()->get_context(fid);
        if u.ctx != &null {
            u.stage = TUStage::Parsing;
            ci->parse_one(fid);
            u.ctx->diag_sink.drain_into(ci->diag(), u.ctx->sm);
            u.tu = reinterpret_cast::<*TranslationUnit>(u.ctx->tu);
        }
    } else {
        u.stage = TUStage::Failed;
    }

    u.errors   = ci->diag()->error_count() - err0;
    u.warnings = ci->diag()->warn_count()  - wrn0;
    u.diags    = collector->diags;
    u.ok       = (u.tu != &null) && (!ci->diag()->has_fatal());
    return u;
}

/// 0 unchanged, 1 changed (reformatted, or would be), 2 refused or failed.
fn format_one_file(ci: *CompilerInstance, path: libcxx::filesystem::path, mode: FmtMode) -> i32 {
    var name: string = path.generic_string();

    var opts = ParseOptions{};
    opts.stop_at       = TUStage::Parsing;   // formatting is syntactic; sema is wasted work
    opts.capture_diags = true;

    var u = parse_alone(ci, name);

    finally {
        // Per-file release: nothing is held across files.
        release_all(ci, TUStage::Lexing);
        ci->diag()->clear_retained();
    }

    // Only syntax errors stop a format: an import that does not resolve from
    // here says nothing about the file's text.
    var bad: u32 = 0;
    for var i: usize = 0; i < u.diags.size(); ++i {
        var d = u.diags[i];
        if !d.is_error() { continue; }
        if (d.severity == DiagSeverity::Fatal) || ((d.code.size() > 0) && (d.code[0] == 'S')) {
            std::print(f"  {d.format()}");
            bad += 1;
        }
    }
    if bad > 0 {
        std::print(f"kfmt: {name}: {bad} syntax error(s), not formatting");
        return 2;
    }

    if (u.tu == &null) || (u.tu->program == &null) {
        std::print(f"kfmt: {name}: no translation unit (fid={u.fid} stage={static_cast::<u32>(u.stage)} ok={u.ok} errors={u.errors} ctx={("set") if (u.ctx != &null) else ("null")})");
        for var i: usize = 0; i < u.diags.size(); ++i {
            std::print(f"  {u.diags[i].format()}");
        }
        return 2;
    }

    var fmt = Formatter(u.ctx, ci, u.fid);
    if !fmt.prepare() {
        std::print(f"kfmt: {name}: could not lex");
        return 2;
    }

    var out  = fmt.run(u.tu->program);
    var orig = fmt.source();

    if out == orig {
        if mode == FmtMode::Stdout { llvm::outs() << sref(out); }
        return 0;
    }

    if !fmt.verify(out, name) {
        std::print(f"kfmt: {name}: output does not round-trip, left unchanged");
        return 2;
    }

    switch mode {
        case FmtMode::Stdout { llvm::outs() << sref(out); }
        case FmtMode::Check  { std::print(f"{name}"); }
        case FmtMode::Write  {
            if !Path::write_file(name, out) {
                std::print(f"kfmt: {name}: cannot write");
                return 2;
            }
        }
    }
    return 1;
}

/// \return the InitLLVM guard; main destroys it before returning.
///
/// \details Kairo.k's init_runtime: see there for why the guard is returned
///          rather than kept in a static.
fn init_runtime(argc: i32, argv: *(*kairo::std::Legacy::char)) -> *llvm::InitLLVM {
    var init_llvm = std::create::<llvm::InitLLVM>(argc, argv);
    llvm::InitializeAllTargetInfos();
    llvm::InitializeAllTargets();
    llvm::InitializeAllTargetMCs();
    llvm::InitializeAllAsmParsers();
    llvm::InitializeAllAsmPrinters();

    llvm::setBugReportMsg(
        r"PLEASE submit a bug report to https://github.com/kairolang/kairo/issues and include the crash backtrace.\n"
    );

    kairo::init_process_locale();

    libcxx::use_facet::<libcxx::num_put::<std::Legacy::char>>(libcxx::locale());
    libcxx::use_facet::<libcxx::num_get::<std::Legacy::char>>(libcxx::locale());

    { // Force narrow char locale facets used by stringstream/to_string
        var oss: libcxx::ostringstream;
        oss << static_cast::<usize>(1) << 1.0;
        oss.str();
    }

    return init_llvm;
}

fn main(argc: i32, argv: *(*kairo::std::Legacy::char)) -> i32 {
    if argc < 2 {
        std::print("Usage: kfmt [--check | --write | --stdout] <file.k | dir> [kairo flags ...]");
        return 1;
    }

    Logger::init(Logger::Level::Trace);
    var llvm_init = init_runtime(argc, argv);

    finally {
        Logger::set_dump_path(
            Path::join_str(Path::parent_of(std::get_exe_path()), "kfmt.log")
        );
        Logger::dump_to_file();
        Logger::shutdown();
        GlobalRecycler::shutdown_allocator_runtime();
        std::destroy(llvm_init);
    }

    // kfmt's own flags come out of argv before the rest reaches kairo's parser
    var mode = FmtMode::Check;
    var n: i32 = 1;
    for var i: i32 = 1; i < argc; ++i {
        if libcxx::strcmp(argv[i], r"--write")  == 0 { mode = FmtMode::Write;  continue; }
        if libcxx::strcmp(argv[i], r"--check")  == 0 { mode = FmtMode::Check;  continue; }
        if libcxx::strcmp(argv[i], r"--stdout") == 0 { mode = FmtMode::Stdout; continue; }
        argv[n] = argv[i];
        n += 1;
    }

    // One instance for the whole walk.
    var ci = std::create::<CompilerInstance>(n, argv);
    finally { std::destroy(ci); }

    if !ci->args_ok() { return 1; }

    var inputs = ci->invocation().input_files;
    if inputs.empty() {
        std::print("kfmt: no input path");
        return 1;
    }

    var target_path = inputs[0];
    var path = libcxx::filesystem::path(sref(target_path).str());

    if !libcxx::filesystem::exists(path) {
        std::print(f"Error: path does not exist: {target_path}");
        return 1;
    }

    ci->initialize(Path::cwd());

    var changed: usize = 0;
    var failed:  usize = 0;

    if libcxx::filesystem::is_directory(path) {
        for entry in libcxx::filesystem::recursive_directory_iterator(path) {
            var ext: string = entry.path().extension().generic_string();
            if (!entry.is_regular_file()) || (ext != ".k") { continue; }
            var r = format_one_file(ci, entry.path(), mode);
            if r == 1 { changed += 1; }
            if r == 2 { failed  += 1; }
        }
    } else {
        var ext: string = path.extension().generic_string();
        if ext != ".k" {
            std::print(f"Error: not a .k file: {target_path}");
            return 1;
        }
        var r = format_one_file(ci, path, mode);
        if r == 1 { changed += 1; }
        if r == 2 { failed  += 1; }
    }

    if mode != FmtMode::Stdout {
        std::print(f"kfmt: {changed} file(s) {("reformatted") if (mode == FmtMode::Write) else ("would change")}, {failed} refused");
    }
    if failed > 0 { return 1; }
    if (mode == FmtMode::Check) && (changed > 0) { return 1; }
    return 0;
}