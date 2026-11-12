/// --- The Kairo Project -------------------- Extras/Formatter/Format.k --- ///
///
///   kfmt's printer: AST + raw tokens -> Doc IR (README is the spec).
///
///   The AST decides layout: blocks, statement / member / item lists, call,
///   parameter, tuple, list and initializer lists (4.1), `&&` / `||` chains
///   (4.6), control-flow conditions (8.2), alignment runs (section 11).
///   Everything the AST cannot reproduce exactly is printed as the source
///   bytes, re-indented: leaves, types, patterns, closure heads, macro
///   invocations (1.7, section 15). Comments, blank lines, imports and
///   anything else the parser keeps out of the lists come from a second, raw
///   lex of the file. Code found between list elements is printed as written.
///
///   No token is printed through the interner. get_spelling rewrites `0xFF`
///   as `255` and `and` as `&&`; every token here is its own source bytes.
///
///   Semicolons (section 13) are decided at layout time, not when an element
///   is built: whether a `;` is redundant depends on what the next line
///   starts with, which only the list knows.
///
///   This file never decides whether its output is safe to write. The
///   driver's checks (Driver/kfmt.k) do: the output must parse, re-lex to the
///   same code and comments, give the same tree, and format to itself.
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

import AST::ASTSupport::*
import AST::Context::ASTContext::*
import AST::Context::DeclContext::*
import AST::Kind::ExprKind::*
import AST::Mixin::Annotation::*
import AST::Node::Base::*
import AST::Node::Casting::*
import AST::Node::Declarations::*
import AST::Node::Expressions::*
import AST::Node::PrimaryExpressions::*
import AST::Node::Program::*
import AST::Node::Statements::*
import AST::Node::Types::*
import DocIR::*
import Driver::CompilerInstance::*
import Lexer::Immediate::*
import Lexer::Lexer::*
import Location::SourceLocation::*
import Location::SourceManager::*
import Location::SourceRange::*
import Options::*
import Renderer::*
import Support::FileIO::Path::*
import Token::Token::*
import Token::TokenKind::*

/// One raw token: what the AST does not keep.
pub struct RawTok {
    var kind:  TokenKind
    var start: u32
    var end:   u32
}

/// Section 11 row kinds: rows join a run only with rows of their kind.
pub fn ROW_NONE()   -> u8 {
    return 0
}

pub fn ROW_ASSIGN() -> u8 { ///< `lhs = rhs`
    return 1
}

pub fn ROW_DECL()   -> u8 { ///< `kw name: Type = init`
    return 2
}

pub fn ROW_ENUM()   -> u8 { ///< `Name = value,`
    return 3
}

pub fn ROW_UNTYPED() -> u8 { ///< `kw name = init`; joins ROW_DECL under Rules.decl_eq_column
    return 4
}

/// Row columns: keyword, name, type, value. A row of any kind fills them
/// (an assignment uses keyword and value only), so one Table layout serves
/// every run.
pub fn ROW_COLS() -> usize {
    return 4
}

/// One element of a list, before layout.
pub struct Entry {
    var doc:        Doc ///< the element, without its `;` or trailing comment
    var cells:      cxx::std::vector<Doc> ///< ROW_COLS cells when row != ROW_NONE
    var row:        u8                    = 0
    var capped:     bool                  = false ///< holds a call: its row must end by call_width (4.1)
    var semi:       bool                  = false ///< written with a `;`
    var sep:        string                = "" ///< a `,` written after it (enum variants)
    var next_kind:  TokenKind             = TokenKind::TkEof ///< first code token after it
    var cmt:        string                = "" ///< trailing comment (12.4)
    var cmt_first:  bool                  = false ///< put the comment on its first line
    var first:      usize                 = 0 ///< source line of its first byte
    var last:       usize                 = 0 ///< source line of its last byte
    var is_comment: bool                  = false
    var imp:        i32                   = -1 ///< index into Formatter::imps
    var member:     bool                  = false ///< a field or variant rule 7.5 may join on one line
    var variant:    bool                  = false ///< an enum variant (its `,` is in its doc)
    var chain_from: bool                  = false ///< ends in a broken block a clause may chain onto (8.4 / 8.11)
    var chain_to:   bool                  = false ///< a clause that chains onto it: a block `case` / `default`, a `finally`
}

/// One thing a list holds, as the AST names it. Exactly one pointer is set.
pub struct Elem {
    var start:   u32                     = 0
    var end:     u32                     = 0
    var decl:    unsafe *Decl            = &null
    var stmt:    unsafe *Stmt            = &null
    var expr:    unsafe *Expr            = &null
    var variant: unsafe *EnumVariantDecl = &null
    var mcase:   unsafe *MatchCase       = &null
}

pub struct ListOut {
    var head:        Doc ///< a comment on the opener's line, as a line suffix
    var body:        Doc
    var empty:       bool = true
    var oneline:     Doc ///< the members joined on one line (7.5), when every one allows it
    var can_oneline: bool = false
}

/// One import statement as written (section 5). Kairo imports are read into
/// parts so they can be restyled and sorted; anything not understood is
/// `raw`: copied as written and never moved.
pub struct ImportInfo {
    var start:  u32                      = 0 ///< first token
    var end:    u32                      = 0 ///< past the last token, its `;` included
    var core:   u32                      = 0 ///< past the last token before the `;`
    var semi:   bool                     = false
    var is_ffi: bool                     = false
    var raw:    bool                     = false
    var vis:    string                   = "" ///< `pub` / `prot` / `priv`, or empty
    var anchor: string                   = "" ///< `self` / `module`, or empty
    var path:   string                   = "" ///< the segments before the tail, `::`-joined
    var braced: bool                     = false
    var star:   bool                     = false
    var alias:  string                   = ""
    var items:  cxx::std::vector<string> ///< braced items, each as `name`, `a::B` or `x as y`
}

/// Lexes \p fid on its own, comments and newlines included.
pub fn lex_file(ci:  unsafe *CompilerInstance,
                fid: u32,
                out: unsafe *cxx::std::vector<RawTok>) -> bool {
    var unsafe *imm = kairo::std::create<ImmediateTable>()
    imm->initialize(ci->sm())
    // No thread pool: a whole-file lex of one file needs none (the pool only
    // serves sub-lexers of nested inputs, which kfmt never opens).
    var unsafe *lx = kairo::std::create<Lexer>(ci->sm(), &null, ci->diag(), imm)
    finally {
        kairo::std::destroy(lx)
        kairo::std::destroy(imm)
    }

    if !lx->open(fid) {
        return false
    }

    var t = Token()
    while lx->next(&t) {
        if t.kind == TokenKind::TkEof {
            break
        }

        // A string chain's later segments stay in the gap after its head,
        // where _chain_end finds them: the head at its own length.
        var end = t.range.start.raw() + chain_head_len(imm, t, t.range.size())
        out->push_back(
            RawTok { kind: t.kind, start: t.range.start.raw(), end: end },
        )
    }

    lx->close()
    return true
}

/// Stage 1 binary precedence (Compiler/Parser/ExprParse.k,
/// _infix_precedence); 0 when \p k is not an infix operator. Rule 9.5 needs
/// it to tell a redundant pair of parens from a needed one.
pub fn infix_prec(k: TokenKind) -> i32 {
    if k == TokenKind::OpEqual
        || k == TokenKind::OpPlusEqual
        || k == TokenKind::OpMinusEqual
        || k == TokenKind::OpStarEqual
        || k == TokenKind::OpSlashEqual
        || k == TokenKind::OpPercentEqual
        || k == TokenKind::OpAmpEqual
        || k == TokenKind::OpPipeEqual
        || k == TokenKind::OpCaretEqual
        || k == TokenKind::OpLessLessEqual
        || k == TokenKind::OpGreaterGreaterEqual {
        return 1
    }

    if k == TokenKind::OpQuestionQuestion {
        return 2
    }

    if k == TokenKind::OpRange || k == TokenKind::OpRangeEqual {
        return 3
    }

    if k == TokenKind::OpPipePipe || k == TokenKind::KwOr {
        return 4
    }

    if k == TokenKind::OpAmpAmp || k == TokenKind::KwAnd {
        return 5
    }

    if k == TokenKind::OpPipe || k == TokenKind::KwBitor {
        return 6
    }

    if k == TokenKind::OpCaret || k == TokenKind::KwXor {
        return 7
    }

    if k == TokenKind::OpAmp || k == TokenKind::KwBitand {
        return 8
    }

    if k == TokenKind::OpEqualEqual
        || k == TokenKind::OpExclaimEqual
        || k == TokenKind::OpEqualEqualEqual
        || k == TokenKind::KwNotEq {
        return 9
    }

    if k == TokenKind::OpLess
        || k == TokenKind::OpGreater
        || k == TokenKind::OpLessEqual
        || k == TokenKind::OpGreaterEqual
        || k == TokenKind::OpLessEqualGreater
        || k == TokenKind::KwIn
        || k == TokenKind::KwImpl
        || k == TokenKind::KwDerives {
        return 10
    }

    if k == TokenKind::OpLessLess || k == TokenKind::OpGreaterGreater {
        return 11
    }

    if k == TokenKind::OpPlus || k == TokenKind::OpMinus {
        return 12
    }

    if k == TokenKind::OpStar || k == TokenKind::OpSlash || k == TokenKind::OpPercent {
        return 13
    }

    if k == TokenKind::OpCaretCaret {
        return 14
    }

    if k == TokenKind::OpDotStar
        || k == TokenKind::OpArrowStar
        || k == TokenKind::OpQuestionDotStar
        || k == TokenKind::OpQuestionArrowStar {
        return 15
    }

    return 0
}

/// Right-associative levels: assignment, `??`, `^^`.
pub fn prec_right_assoc(p: i32) -> bool {
    return p == 1 || p == 2 || p == 14
}

/// Rule 4.4 / 13.1: a line starting with \p k continues the statement on the
/// line before it, so a `;` ending that line is not redundant. The parser's
/// own sets: the member-access family (_parse_postfix_expr), any infix
/// operator that cannot also open a statement (_parse_expr_prec), and the
/// keywords that continue a head or an expression.
pub fn continues_statement(k: TokenKind) -> bool {
    if k == TokenKind::OpDot
        || k == TokenKind::OpArrow
        || k == TokenKind::OpQuestionDot
        || k == TokenKind::OpQuestionArrow {
        return true
    }

    if !is_unary_operator(k) && infix_prec(k) != 0 {
        return true
    }

    return k == TokenKind::KwElse
        || k == TokenKind::KwCatch
        || k == TokenKind::OpFatArrow
        || k == TokenKind::KwWhere
        || k == TokenKind::KwRequires
        || k == TokenKind::KwDerives
        || k == TokenKind::KwImpl
}

/// Operand context for rule 9.5: where an expression sits decides whether a
/// pair of parens around it is needed.
pub struct PCtx {
    var kind:  u8   = 0 ///< 0 value, 1 binary operand, 2 prefix operand, 3 postfix operand, 4 never touch
    var prec:  i32  = 0 ///< the parent operator's precedence (kind 1)
    var right: bool = false ///< right-hand operand (kind 1)
}

pub class Formatter {
    pub var ctx:      unsafe *ASTContext
    pub var ci:       unsafe *CompilerInstance
    pub var sm:       unsafe *SourceManager
    pub var fid:      u32                      = 0
    pub var base:     u32                      = 0  ///< raw location of byte 0
    pub var size:     u32                      = 0  ///< file size in bytes
    pub var set:      Settings
    pub var file_dir: string                   = "" ///< for the 5.1 module-collision test
    pub var roots:    cxx::std::vector<string>      ///< search roots, likewise

    pub var toks:          cxx::std::vector<RawTok> ///< every token, comments and newlines included
    pub var imps:          cxx::std::vector<ImportInfo>
    var     cm_lo:         cxx::std::vector<u32> ///< comment starts, ascending
    var     ms_lo:         cxx::std::vector<u32> ///< macro invocation sites, ascending, disjoint
    var     ms_hi:         cxx::std::vector<u32>
    var     cb_lo:         cxx::std::vector<u32> ///< closure block bodies `{`..`}`, ascending by start; may nest
    var     cb_hi:         cxx::std::vector<u32>
    var     lstart:        cxx::std::vector<u32> ///< line start offsets, line 1 first
    var     src:           string                       = "" ///< the file's bytes
    var     _depth:        i32                          = 0 ///< block nesting, for alignment fits
    var     _calls:        usize                        = 0 ///< calls built so far (Entry::capped)
    var     _ungroup_next: bool                         = false ///< the next _block leaves its one-line group to its chain
    var     _blk_broken:   bool                         = false ///< the last _block ended in a `}` line of its own
    var     _braced_empty: bool                         = false ///< the last _braced was `{ }`

    fn Formatter(self,
                 ctx: unsafe *ASTContext,
                 ci:  unsafe *CompilerInstance,
                 fid: u32,
                 set: Settings) {
        self.ctx = ctx
        self.ci  = ci
        self.sm  = ci->sm()
        self.fid = fid
        self.set = set
    }

    // ----------------------------------------------------------------------
    //  Setup
    // ----------------------------------------------------------------------

    fn prepare(self) -> bool {
        self.base = self.sm->get_loc(self.fid, 0).raw()
        self.size = self.sm->get_file_size(self.fid) as u32

        // The bytes, once. SourceManager::get_text decodes to code points and
        // narrows each to a byte (it is a debugging aid), which would turn
        // every non-ASCII comment into garbage.
        if self.size > 0 {
            var view = self.sm->get_view(
                SourceRange::from_bounds(
                    SourceLocation::from_raw(self.base),
                    SourceLocation::from_raw(self.base + self.size),
                ),
            )

            var unsafe *p = view.data()
            self.src = string(
                unsafe ((p as unsafe *const u8) as *const u8),
                view.size(),
            )
        }

        // Our own line table: the source manager's is not part of its API,
        // and a virtual buffer (the output being checked) needs one too.
        var src = self.src
        self.lstart.push_back(0)
        for var i: usize = 0; i < src.size(); ++i {
            if src[i] == ('\n' as u8) {
                self.lstart.push_back((i + 1) as u32)
            }
        }

        if !lex_file(self.ci, self.fid, unsafe &self.toks) {
            return false
        }

        var n = self.toks.size()
        for var i: usize = 0; i < n; ++i {
            if self.toks[i].kind == TokenKind::AtComment {
                self.cm_lo.push_back(self.toks[i].start)
            }
        }

        // `name!` glued, plus a bracket group glued to the `!`
        var i: usize = 0
        while i + 1 < n {
            var a = self.toks[i]
            var b = self.toks[i + 1]
            if a.kind != TokenKind::LitIdentifier
                || b.kind != TokenKind::OpExclaim
                || b.start != a.end {
                i += 1
                continue
            }

            var end = b.end
            var j   = i + 2
            if j < n && self.toks[j].start == end && Formatter::_is_open(self.toks[j].kind) {
                var depth: i32 = 0
                while j < n {
                    if Formatter::_is_open(self.toks[j].kind) {
                        depth += 1
                    }

                    if Formatter::_is_close(self.toks[j].kind) {
                        depth -= 1
                    }

                    end = self.toks[j].end
                    j += 1
                    if depth == 0 {
                        break
                    }
                }
            }

            self.ms_lo.push_back(a.start)
            self.ms_hi.push_back(end)
            i = j
        }

        self._scan_closures()
        self._scan_imports()
        return true
    }

    /// Every closure's block body, from the tokens: `fn` then `(` (or a
    /// `<...>` and `(`), the parameter list, a head with nothing at depth 0
    /// that ends an expression, then `{`. A `fn` type (`cb: fn(u32) -> bool`)
    /// reaches `)` / `,` / `=` / the line's end first and is not one. A
    /// body missed here only means the old, copied layout.
    priv fn _scan_closures(self) {
        var n = self.toks.size()
        for var i: usize = 0; i < n; ++i {
            if self.toks[i].kind != TokenKind::KwFn {
                continue
            }

            var j = self._sig_after(self.toks[i].end)
            if self._kind_at(j) == TokenKind::OpLess {
                var ad: i32 = 0
                while j < n {
                    var k = self.toks[j].kind
                    if k == TokenKind::OpLess {
                        ad += 1
                    } else if k == TokenKind::OpGreater {
                        ad -= 1
                    } else if k == TokenKind::OpLBrace || k == TokenKind::OpSemicolon {
                        break
                    }

                    j += 1
                    if ad == 0 {
                        break
                    }
                }

                j = if j < n => self._sig_after(self.toks[j - 1].end) else => n
            }

            if self._kind_at(j) != TokenKind::OpLParen {
                continue
            }

            var c = self._match_close(j)
            if c >= n {
                continue
            }

            // the head after the parameters: captures, `-> T`, `panic(E)`
            var o          = n
            var depth: i32 = 0
            var cap        = false
            var k          = c + 1
            while k < n {
                var t = self.toks[k].kind
                if t == TokenKind::TkWhitespace || t == TokenKind::AtComment {
                    k += 1
                    continue
                }

                // the capture list `|a, b|`: its commas end nothing
                if t == TokenKind::OpPipe {
                    cap = !cap
                    k += 1
                    continue
                }

                if depth == 0 && !cap {
                    if t == TokenKind::OpLBrace {
                        o = k
                        break
                    }

                    if t == TokenKind::TkNewLine
                        || Formatter::_is_close(t)
                        || t == TokenKind::OpComma
                        || t == TokenKind::OpSemicolon
                        || t == TokenKind::OpEqual
                        || t == TokenKind::OpFatArrow {
                        break
                    }
                }

                if t == TokenKind::OpLParen || t == TokenKind::OpLSquare {
                    depth += 1
                } else if t == TokenKind::OpRParen || t == TokenKind::OpRSquare {
                    depth -= 1
                }

                k += 1
            }

            if o >= n {
                continue
            }

            var bd: i32 = 0
            var z       = o
            while z < n {
                var t = self.toks[z].kind
                if t == TokenKind::OpLBrace {
                    bd += 1
                } else if t == TokenKind::OpRBrace {
                    bd -= 1
                    if bd == 0 {
                        break
                    }
                }

                z += 1
            }

            if z >= n {
                continue
            }

            self.cb_lo.push_back(self.toks[o].start)
            self.cb_hi.push_back(self.toks[z].end)
        }
    }

    /// \p p lies in a closure body that [a, b) holds whole. A comment or a
    /// macro use there belongs to that body's own statement list, which
    /// keeps it; it does not make the call or statement around the closure
    /// copied as written.
    priv fn _in_held_closure(self, p: u32, a: u32, b: u32) -> bool {
        var lo: usize = 0
        var hi        = self.cb_lo.size()
        while lo < hi {
            var mid = lo + (hi - lo) / 2
            if self.cb_lo[mid] < a {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        for var k = lo; k < self.cb_lo.size() && self.cb_lo[k] <= p; ++k {
            if self.cb_hi[k] <= b && p < self.cb_hi[k] {
                return true
            }
        }

        return false
    }

    /// The file as it is on disk.
    fn source(self) -> string {
        return self._text(self.base, self.base + self.size)
    }

    fn run(self, prog: unsafe *Program) -> string {
        var els = cxx::std::vector<Elem>()
        for var i: usize = 0; i < prog->items.size(); ++i {
            var unsafe *item = prog->items.get(i)
            if item == &null {
                continue
            }

            match item->get_kind() {
                case TopLevelKind::Decl {
                    self._push_decl(item->as_decl(), unsafe &els)
                } case TopLevelKind::Stmt {
                    self._push_stmt(item->as_stmt(), unsafe &els)
                } case TopLevelKind::Expr {
                    var unsafe *e = item->as_expr()
                    if e != &null {
                        els.push_back(
                            Elem { start: e->range.start.raw(), end: e->range.end.raw(), expr: e },
                        )
                    }
                }
            }
        }

        var l   = self._list(self.base, self.base + self.size, 0, unsafe &els)
        var out = Renderer::render(unsafe &l.body, self.set)
        // 3.5: the renderer writes LF; with the rule off a CRLF file keeps CRLF
        if !rules().crlf_to_lf && find_str(self.src, "\r\n") < self.src.size() {
            var crlf: string = ""
            for var i: usize = 0; i < out.size(); ++i {
                if out[i] == ('\n' as u8) {
                    crlf.push_back('\r' as u8)
                }

                crlf.push_back(out[i])
            }

            return crlf
        }

        return out
    }

    // ----------------------------------------------------------------------
    //  Source text and lines
    // ----------------------------------------------------------------------

    fn _text(self, a: u32, b: u32) -> string {
        if b <= a || a < self.base {
            return ""
        }

        return self.src.subslice((a - self.base) as usize, (b - a) as usize)
    }

    fn _tok(self, t: Token) -> string {
        return self._text(t.range.start.raw(), t.range.end.raw())
    }

    fn tok_text(self, i: usize) -> string {
        return self._text(self.toks[i].start, self.toks[i].end)
    }

    priv static fn _ws(c: u8) -> bool {
        return c == (' ' as u8) || c == ('\t' as u8) || c == ('\n' as u8) || c == ('\r' as u8)
    }

    /// \p b moved back over trailing whitespace (all of it, or only line
    /// breaks). Whitespace is ASCII, so characters dropped are bytes dropped.
    priv fn _trim_back(self, a: u32, b: u32, spaces_too: bool) -> u32 {
        var t        = self._text(a, b)
        var n        = t.size()
        var k: usize = 0
        while k < n {
            var c = t[n - 1 - k]
            var drop = c == ('\n' as u8)
                || c == ('\r' as u8)
                || spaces_too && (c == (' ' as u8) || c == ('\t' as u8))
            if !drop {
                break
            }

            k += 1
        }

        return b - (k as u32)
    }

    fn _trimmed(self, a: u32, b: u32) -> string {
        var t        = self._text(a, b)
        var n        = t.size()
        var l: usize = 0
        while l < n && Formatter::_ws(t[l]) {
            l += 1
        }

        if l == n {
            return ""
        }

        var r: usize = 0
        while r < n && Formatter::_ws(t[n - 1 - r]) {
            r += 1
        }

        return self._text(a + (l as u32), b - (r as u32))
    }

    /// 1-based source line of the byte at raw location \p a.
    fn _line(self, a: u32) -> usize {
        var off       = a - self.base
        var lo: usize = 0
        var hi        = self.lstart.size()
        while lo + 1 < hi {
            var mid = lo + (hi - lo) / 2
            if self.lstart[mid] <= off {
                lo = mid
            } else {
                hi = mid
            }
        }

        return lo + 1
    }

    priv fn _line_start(self, l: usize) -> u32 {
        return self.base + self.lstart[l - 1]
    }

    /// End of line \p l, its line break excluded.
    priv fn _line_end(self, l: usize) -> u32 {
        var a = self._line_start(l)
        var b = if l < self.lstart.size() => self.base + self.lstart[l]
                else => self.base + self.size
        return self._trim_back(a, b, false)
    }

    /// Bytes of indentation at the start of [a, b).
    priv fn _lead_ws(self, a: u32, b: u32) -> u32 {
        var t        = self._text(a, b)
        var k: usize = 0
        while k < t.size() && (t[k] == (' ' as u8) || t[k] == ('\t' as u8)) {
            k += 1
        }

        return k as u32
    }

    // ----------------------------------------------------------------------
    //  Token index
    // ----------------------------------------------------------------------

    priv static fn _is_open(k: TokenKind) -> bool {
        return k == TokenKind::OpLParen || k == TokenKind::OpLSquare || k == TokenKind::OpLBrace
    }

    priv static fn _is_close(k: TokenKind) -> bool {
        return k == TokenKind::OpRParen || k == TokenKind::OpRSquare || k == TokenKind::OpRBrace
    }

    static fn trivia(k: TokenKind) -> bool {
        return k == TokenKind::TkNewLine
            || k == TokenKind::TkWhitespace
            || k == TokenKind::AtComment
    }

    /// Index of the first token starting at or after \p a.
    fn _lb(self, a: u32) -> usize {
        var lo: usize = 0
        var hi        = self.toks.size()
        while lo < hi {
            var mid = lo + (hi - lo) / 2
            if self.toks[mid].start < a {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        return lo
    }

    /// First code token starting at or after \p a; toks.size() if none.
    fn _sig_after(self, a: u32) -> usize {
        var n = self.toks.size()
        for var i = self._lb(a); i < n; ++i {
            if !Formatter::trivia(self.toks[i].kind) {
                return i
            }
        }

        return n
    }

    /// Last code token ending at or before \p b; toks.size() if none.
    fn _sig_before(self, b: u32) -> usize {
        var i = self._lb(b)
        while i > 0 {
            i -= 1
            if self.toks[i].end <= b && !Formatter::trivia(self.toks[i].kind) {
                return i
            }
        }

        return self.toks.size()
    }

    fn _comment_in(self, a: u32, b: u32) -> bool {
        var lo: usize = 0
        var hi        = self.cm_lo.size()
        while lo < hi {
            var mid = lo + (hi - lo) / 2
            if self.cm_lo[mid] < a {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        while lo < self.cm_lo.size() && self.cm_lo[lo] < b {
            if !self._in_held_closure(self.cm_lo[lo], a, b) {
                return true
            }

            lo += 1
        }

        return false
    }

    /// The macro site overlapping [a, b), or ms_lo.size().
    priv fn _macro_at(self, a: u32, b: u32) -> usize {
        var lo: usize = 0
        var hi        = self.ms_hi.size()
        while lo < hi {
            var mid = lo + (hi - lo) / 2
            if self.ms_hi[mid] <= a {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        if lo < self.ms_lo.size() && self.ms_lo[lo] < b {
            return lo
        }

        return self.ms_lo.size()
    }

    priv fn _macro_in(self, a: u32, b: u32) -> bool {
        var m = self._macro_at(a, b)
        while m < self.ms_lo.size() && self.ms_lo[m] < b {
            if !self._in_held_closure(self.ms_lo[m], a, b) {
                return true
            }

            m += 1
        }

        return false
    }

    /// \p a moved back over the `(` tokens right before it. An operator
    /// expression's range starts at its first operand's, inside that
    /// operand's parens (`(a * b) + c` starts at `a`); where the grammar puts
    /// nothing but the expression after a keyword or `=`, those parens are
    /// the expression's own.
    fn _lead_start(self, a: u32) -> u32 {
        var s = a
        var p = self._sig_before(s)
        while self._kind_at(p) == TokenKind::OpLParen {
            s = self.toks[p].start
            p = self._sig_before(s)
        }

        return s
    }

    /// Any code token in [a, b).
    priv fn _has_sig(self, a: u32, b: u32) -> bool {
        var i = self._sig_after(a)
        return i < self.toks.size() && self.toks[i].start < b
    }

    fn _kind_at(self, i: usize) -> TokenKind {
        if i >= self.toks.size() {
            return TokenKind::TkUnknown
        }

        return self.toks[i].kind
    }

    /// The last code token in [a, b) is \p k, or the first one after it is.
    priv fn _has_sep(self, a: u32, b: u32, k: TokenKind) -> bool {
        var l = self._sig_before(b)
        if l < self.toks.size() && self.toks[l].start >= a && self.toks[l].kind == k {
            return true
        }

        return self._kind_at(self._sig_after(b)) == k
    }

    /// \p b moved back before a trailing `;` or `,` that sits inside [a, b).
    priv fn _core_end(self, a: u32, b: u32) -> u32 {
        var l = self._sig_before(b)
        if l >= self.toks.size() || self.toks[l].start < a {
            return b
        }

        var k = self.toks[l].kind
        if k != TokenKind::OpSemicolon && k != TokenKind::OpComma {
            return b
        }

        var p = self._sig_before(self.toks[l].start)
        if p >= self.toks.size() || self.toks[p].start < a {
            return b
        }

        return self.toks[p].end
    }

    /// Past the `;` / `,` glued to the end of an element.
    priv fn _skip_seps(self, b: u32) -> u32 {
        var cur = b
        var i   = self._lb(b)
        while i < self.toks.size() {
            var k = self.toks[i].kind
            if k == TokenKind::TkWhitespace {
                i += 1
                continue
            }

            if k != TokenKind::OpSemicolon && k != TokenKind::OpComma {
                break
            }

            cur = self.toks[i].end
            i += 1
        }

        return cur
    }

    // ----------------------------------------------------------------------
    //  Source text as Docs
    // ----------------------------------------------------------------------

    /// [a, b) as written. Continuation lines keep their indentation relative
    /// to the first line's and follow the output indent. A multi-line string
    /// or char literal in the range pins every line to column 0 instead:
    /// re-indenting it would change its value.
    fn _v(self, a: u32, b: u32) -> Doc {
        if b <= a {
            return Doc::nothing()
        }

        var l1 = self._line(a)
        var l2 = self._line(b - 1)
        if l1 == l2 {
            return Doc::text(self._text(a, b))
        }

        var exact = self._has_ml_literal(a, b)
        var base  = self._lead_ws(self._line_start(l1), self._line_end(l1))
        var parts = cxx::std::vector<Doc>()

        var e1 = self._line_end(l1)
        if !exact {
            e1 = self._trim_back(a, e1, true)
        }

        parts.push_back(Doc::text(self._text(a, e1)))

        for var l = l1 + 1; l <= l2; ++l {
            var ls = self._line_start(l)
            var le = if l == l2 => b else => self._line_end(l)

            if exact {
                parts.push_back(Doc::literal_line())
                parts.push_back(Doc::text(self._text(ls, le)))
                continue
            }

            le = self._trim_back(ls, le, true)
            var ws = self._lead_ws(ls, le)
            parts.push_back(Doc::hardline())
            if ls + ws >= le { // blank: no indent written
                continue
            }

            var cut = if ws < base => ws else => base
            parts.push_back(Doc::text(self._text(ls + cut, le)))
        }

        return Doc::concat(parts)
    }

    priv fn _has_ml_literal(self, a: u32, b: u32) -> bool {
        for var i = self._lb(a); i < self.toks.size(); ++i {
            var t = self.toks[i]
            if t.start >= b {
                break
            }

            if t.kind != TokenKind::LitString && t.kind != TokenKind::LitChar {
                continue
            }

            if self._line(t.start) != self._line(t.end - 1) {
                return true
            }
        }

        return false
    }

    /// The tokens in [a, b) as written, whitespace at both ends dropped.
    fn _span(self, a: u32, b: u32) -> Doc {
        var n = self.toks.size()
        var i = self._lb(a)
        while i < n
            && (self.toks[i].kind == TokenKind::TkNewLine
                || self.toks[i].kind == TokenKind::TkWhitespace) {
            i += 1
        }

        if i >= n || self.toks[i].start >= b {
            return Doc::nothing()
        }

        var j = self._lb(b)
        while j > i {
            var t = self.toks[j - 1]
            if t.kind != TokenKind::TkNewLine && t.kind != TokenKind::TkWhitespace && t.end <= b {
                break
            }

            j -= 1
        }

        var s0 = self._prefix_start(self.toks[i].start)
        if s0 < a {
            s0 = self.toks[i].start
        }

        var lt = if j <= i => i else => j - 1
        var e1 = self.toks[lt].end
        if self.toks[lt].kind == TokenKind::LitString {
            var c = self._chain_end(lt)
            if c <= b {
                e1 = c
            }
        }

        return self._v(s0, e1)
    }

    // ----------------------------------------------------------------------
    //  Imports (section 5)
    // ----------------------------------------------------------------------

    /// True when token \p i is the first code token on its line.
    priv fn _line_head(self, i: usize) -> bool {
        var j = i
        while j > 0 {
            j -= 1
            var k = self.toks[j].kind
            if k == TokenKind::TkWhitespace {
                continue
            }

            return k == TokenKind::TkNewLine
                || k == TokenKind::AtComment
                    && self._line(self.toks[j].start) != self._line(
                        self.toks[i].start,
                    )
        }

        return true
    }

    /// A word token: an identifier or a keyword, usable as a path segment.
    priv fn _wordlike(self, i: usize) -> bool {
        if i >= self.toks.size() {
            return false
        }

        var k = self.toks[i].kind
        if k == TokenKind::LitIdentifier {
            return true
        }

        var t = self.tok_text(i)
        if t.size() == 0 {
            return false
        }

        var c = t[0]
        return c >= ('a' as u8) && c <= ('z' as u8)
            || c >= ('A' as u8) && c <= ('Z' as u8)
            || c == ('_' as u8)
    }

    /// Next token index after \p i that is not whitespace (newlines count).
    priv fn _next_tok(self, i: usize) -> usize {
        var j = i + 1
        while j < self.toks.size() && self.toks[j].kind == TokenKind::TkWhitespace {
            j += 1
        }

        return j
    }

    /// Next code token after \p i, skipping newlines and comments too.
    priv fn _next_code(self, i: usize) -> usize {
        var j = i + 1
        while j < self.toks.size() && Formatter::trivia(self.toks[j].kind) {
            j += 1
        }

        return j
    }

    /// Every import statement that starts a line, in source order.
    priv fn _scan_imports(self) {
        var n = self.toks.size()
        for var i: usize = 0; i < n; ++i {
            var k      = self.toks[i].kind
            var is_vis = k == TokenKind::KwPub || k == TokenKind::KwPriv || k == TokenKind::KwProt
            if k != TokenKind::KwImport && k != TokenKind::KwFfi && !is_vis {
                continue
            }

            if !self._line_head(i) {
                continue
            }

            var im = ImportInfo{}
            im.start = self.toks[i].start
            var j = i

            if k == TokenKind::KwFfi {
                var s = self._next_tok(j)
                if self._kind_at(s) != TokenKind::LitString {
                    continue
                }

                var m = self._next_tok(s)
                if self._kind_at(m) != TokenKind::KwImport {
                    continue
                }

                var h = self._next_tok(m)
                if self._kind_at(h) != TokenKind::LitString {
                    continue
                }

                im.is_ffi = true
                j         = h
                var a = self._next_tok(j)
                if self._kind_at(a) == TokenKind::KwAs && self._wordlike(self._next_tok(a)) {
                    j = self._next_tok(a)
                }
            } else {
                if is_vis {
                    im.vis = self.tok_text(i)
                    j      = self._next_tok(i)
                    if self._kind_at(j) != TokenKind::KwImport {
                        continue
                    }
                }

                if !self._read_kairo_import(j, &im, unsafe &j) {
                    continue
                }
            }

            im.core = self.toks[j].end
            im.end  = im.core
            var s = self._next_tok(j)
            if self._kind_at(s) == TokenKind::OpSemicolon {
                im.semi = true
                im.end  = self.toks[s].end
                s       = self._next_tok(s)
            }

            // the statement must end its line; anything else is not ours to touch
            var tail = self._kind_at(s)
            if tail != TokenKind::TkNewLine && tail != TokenKind::AtComment && s < n {
                continue
            }

            if self._comment_in(im.start, im.core) {
                im.raw = true
            }

            self.imps.push_back(im)
            i = s
        }
    }

    /// `import [anchor::]a::b[::{x, y} | ::* | as z]`, from the `import` at
    /// \p i. \p last gets the index of its last token.
    priv fn _read_kairo_import(self, i: usize, im: *ImportInfo, last: unsafe *usize) -> bool {
        var j  = self._next_tok(i)
        var k0 = self._kind_at(j)
        if (k0 == TokenKind::KwSelf || k0 == TokenKind::KwModule)
            && self._kind_at(self._next_tok(j)) == TokenKind::OpColonColon {
            im->anchor = self.tok_text(j)
            j          = self._next_tok(self._next_tok(j))
        }

        if !self._wordlike(j) {
            return false
        }

        var path: string = self.tok_text(j)
        var end          = j
        while true {
            var c = self._next_tok(end)
            if self._kind_at(c) != TokenKind::OpColonColon {
                break
            }

            var nx = self._next_tok(c)
            var kn = self._kind_at(nx)
            if kn == TokenKind::OpStar {
                im->star = true
                end      = nx
                break
            }

            if kn == TokenKind::OpLBrace {
                im->braced = true
                if !self._read_items(nx, im, unsafe &end) {
                    return false
                }

                break
            }

            if !self._wordlike(nx) {
                return false
            }

            path += "::"
            path += self.tok_text(nx)
            end = nx
        }

        im->path = path

        if !im->braced && !im->star {
            var a = self._next_tok(end)
            if self._kind_at(a) == TokenKind::KwAs {
                var nm = self._next_tok(a)
                if !self._wordlike(nm) {
                    return false
                }

                im->alias = self.tok_text(nm)
                end       = nm
            }
        }

        *last = end
        return true
    }

    /// The items of `{ ... }` opening at \p open; \p last gets the `}`.
    priv fn _read_items(self, open: usize, im: *ImportInfo, last: unsafe *usize) -> bool {
        var j           = self._next_code(open)
        var cur: string = ""
        while j < self.toks.size() {
            var k = self.toks[j].kind
            if k == TokenKind::OpRBrace {
                if cur.size() > 0 {
                    im->items.push_back(cur)
                }

                *last = j
                return im->items.size() > 0
            }

            if k == TokenKind::OpComma {
                if cur.size() == 0 {
                    return false
                }

                im->items.push_back(cur)
                cur = ""
            } else if k == TokenKind::KwAs {
                cur += " as "
            } else if k == TokenKind::OpColonColon || k == TokenKind::OpStar || self._wordlike(j) {
                cur += self.tok_text(j)
            } else {
                return false
            }

            j = self._next_code(j)
        }

        return false
    }

    /// Import index starting at \p a, or -1.
    priv fn _import_at(self, a: u32) -> i32 {
        var lo: usize = 0
        var hi        = self.imps.size()
        while lo < hi {
            var mid = lo + (hi - lo) / 2
            if self.imps[mid].start < a {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        if lo < self.imps.size() && self.imps[lo].start == a {
            return lo as i32
        }

        return -1
    }

    /// 5.1's exception (Scripts/import_lint.py, module_exists): `import
    /// P::{x}` without braces names the MODULE `P/x` when that file exists,
    /// so the braces stay. Checked against the file's directory, every
    /// directory above it (the tree roots are among them), their `Lib/`, and
    /// the -I roots: more places checked only keeps more braces.
    priv fn _module_exists(self, segs: string) -> bool {
        var rel: string = ""
        var i:   usize  = 0
        while i < segs.size() {
            if i + 1 < segs.size() && segs[i] == (':' as u8) && segs[i + 1] == (':' as u8) {
                rel += "/"
                i += 2
                continue
            }

            rel.push_back(segs[i])
            i += 1
        }

        var bases = cxx::std::vector<string>()
        var d     = self.file_dir
        while d.size() > 0 {
            bases.push_back(d)
            bases.push_back(Path::join_str(d, "Lib"))
            var p = Path::parent_of(d)
            if p == d || p.size() == 0 {
                break
            }

            d = p
        }

        for var r: usize = 0; r < self.roots.size(); ++r {
            bases.push_back(self.roots[r])
        }

        for var b: usize = 0; b < bases.size(); ++b {
            var f = Path::join_str(bases[b], rel)
            if Path::exists_at(f + ".k") || Path::exists_at(Path::join_str(f, "module.k")) {
                return true
            }
        }

        return false
    }

    /// The import's text as kfmt prints it (rules 5.1, 5.2, 5.5), without
    /// the list for a braced import of two or more names: see _import_doc.
    fn import_head(self, im: ImportInfo) -> string {
        var s: string = ""
        if im.vis.size() > 0 {
            s += im.vis + " "
        }

        s += "import "
        if im.anchor.size() > 0 {
            s += im.anchor + "::"
        }

        s += im.path
        return s
    }

    /// The braced items in print order (5.2: sorted like 5.4).
    fn import_items(self, im: ImportInfo) -> cxx::std::vector<string> {
        var xs = im.items
        if rules().import_sort_items {
            sort_strings(unsafe &xs)
        }

        return xs
    }

    /// One item that loses its braces under 5.1, or "" when the braces stay.
    fn unbraced_item(self, im: ImportInfo) -> string {
        if !im.braced || im.items.size() != 1 {
            return ""
        }

        var it = im.items[0]
        if it == "*" {
            return if rules().import_unbrace_more => it else => ""
        }

        var base = it
        var cut  = find_str(it, " as ")
        if cut < it.size() {
            base = it.subslice(0, cut)
        }

        var nested = find_str(base, "::") < base.size()
        if nested && !rules().import_unbrace_more {
            return ""
        }

        if self._module_exists(im.path + "::" + base) {
            return ""
        }

        return it
    }

    /// 5.4's sort key: the path as printed, then the tail, the visibility and
    /// the anchor (Scripts/import_lint.py, Import.sort_key). The parts are
    /// joined by \x01, below every printable byte, so comparing the joined
    /// strings is comparing the tuples.
    fn import_key(self, im: ImportInfo) -> string {
        var path         = im.path
        var tail: string = ""
        var one          = self.unbraced_item(im)
        if one.size() > 0 {
            var cut = find_str(one, " as ")
            if cut < one.size() {
                path += "::" + one.subslice(0, cut)
                tail = "as " + one.subslice(cut + 4, one.size() - cut - 4)
            } else {
                path += "::" + one
            }
        } else if im.braced {
            var xs = self.import_items(im)
            tail = "::{"
            for var i: usize = 0; i < xs.size(); ++i {
                if i > 0 {
                    tail += ", "
                }

                tail += xs[i]
            }

            tail += "}"
        } else if im.star {
            tail = "::*"
        } else if im.alias.size() > 0 {
            tail = "as " + im.alias
        }

        return path + "\x01" + tail + "\x01" + im.vis + "\x01" + im.anchor
    }

    priv fn _import_doc(self, idx: usize) -> Doc {
        var im = self.imps[idx]
        if im.is_ffi || im.raw {
            return self._v(im.start, im.core)
        }

        var head = self.import_head(im)
        if im.star {
            return Doc::text(head + "::*")
        }

        if !im.braced {
            if im.alias.size() > 0 {
                return Doc::text(head + " as " + im.alias)
            }

            return Doc::text(head)
        }

        var one = self.unbraced_item(im)
        if one.size() > 0 {
            return Doc::text(head + "::" + one)
        }

        if im.items.size() == 1 {
            return Doc::text(head + "::{" + im.items[0] + "}")
        }

        // 5.2: two or more names are always broken, block or grid form
        var xs   = self.import_items(im)
        var keys = cxx::std::vector<Doc>()
        var vals = cxx::std::vector<Doc>()
        for var i: usize = 0; i < xs.size(); ++i {
            keys.push_back(Doc::nothing())
            vals.push_back(Doc::text(xs[i]))
        }

        var flags = LIST_FORCE()
        if xs.size() > import_block_max() {
            flags |= LIST_GRID()
        }

        return Doc::concat2(
            Doc::text(head + "::"),
            Doc::list("{", "}", keys, vals, Doc::nothing(), flags),
        )
    }

    // ----------------------------------------------------------------------
    //  Lists: statements, members, items, enum variants, match cases
    // ----------------------------------------------------------------------

    priv fn _push_decl(self, d: unsafe *Decl, els: unsafe *cxx::std::vector<Elem>) {
        if d == &null || d->range.is_invalid() {
            return
        }

        els->push_back(
            Elem { start: self._decl_start(d), end: d->range.end.raw(), decl: d },
        )
    }

    priv fn _push_stmt(self, s: unsafe *Stmt, els: unsafe *cxx::std::vector<Elem>) {
        if s == &null || s->range.is_invalid() {
            return
        }

        // a declaration statement's range starts after its `pub` / attributes
        // (`eval if c { pub eval N: usize = 1 }` at file scope); left out,
        // the `pub` is uncovered code and lands on a line of its own
        var a = s->range.start.raw()
        if isa<DeclStmt>(s) && cast<DeclStmt>(s)->decl != &null {
            var d = self._decl_start(cast<DeclStmt>(s)->decl)
            if d < a {
                a = d
            }
        }

        els->push_back(Elem { start: a, end: s->range.end.raw(), stmt: s })
    }

    priv fn _push_dc(self, dc: unsafe *DeclContext, els: unsafe *cxx::std::vector<Elem>) {
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            self._push_decl(*dc->dc_decls.get(i), els)
        }
    }

    /// Where a decl's text starts: its visibility keyword or first attribute.
    /// Comment annotations are not counted; the token stream owns comments.
    priv fn _decl_start(self, d: unsafe *Decl) -> u32 {
        var a = d->range.start.raw()
        if d->has_visibility() {
            var v = d->_visibility_range.start.raw()
            if v != 0 && v < a {
                a = v
            }
        }

        for var i: usize = 0; i < d->annotations.size(); ++i {
            var unsafe *ae = d->annotations.get(i)
            if ae->kind != AnnotationKind::Attribute {
                continue
            }

            var r = ae->range.start.raw()
            if r != 0 && r < a {
                a = r
            }
        }

        return a
    }

    priv fn _sort(self, els: unsafe *cxx::std::vector<Elem>) {
        for var i: usize = 1; i < els->size(); ++i {
            var j = i
            while j > 0 && (*els)[j - 1].start > (*els)[j].start {
                var t = (*els)[j]
                (*els)[j]     = (*els)[j - 1]
                (*els)[j - 1] = t
                j -= 1
            }
        }
    }

    /// Lays out the elements of the region [lo, hi), with everything between
    /// them: comments, blank lines (rule 14.1), imports, and code no element
    /// covers. \p opener is the line of the region's `{`, or 0 at file scope.
    priv fn _list(self,
                  lo:     u32,
                  hi:     u32,
                  opener: usize,
                  els:    unsafe *cxx::std::vector<Elem>) -> ListOut {
        self._sort(els)

        var r    = ListOut{}
        var es   = cxx::std::vector<Entry>()
        var cur  = lo
        var done = lo

        for var i: usize = 0; i < els->size(); ++i {
            var el = (*els)[i]

            // a duplicate, or inside something already printed
            if el.start < done || el.end <= el.start || el.start < lo || el.end > hi {
                continue
            }

            var st   = el.start
            var en   = el.end
            var verb = false

            // expanded macros: everything they made shares the invocation's
            // range, so an element that STARTS inside a macro site is the
            // macro's output and is copied as written. An element that merely
            // contains a macro use (`var x = f!(y)`, a fn or class whose body
            // has an `eval if defined!(X)`) is not: it is laid out like any
            // other and the use is copied where it sits. Taking any
            // overlap here copied every declaration holding a macro verbatim.
            var m = self._macro_at(st, en)
            if m < self.ms_lo.size() && self.ms_lo[m] <= st && st < self.ms_hi[m] {
                if self.ms_lo[m] < st {
                    st = self.ms_lo[m]
                }

                if self.ms_hi[m] > en {
                    en = self.ms_hi[m]
                }

                verb = true
            }

            // a range can start or end inside its own first / last operand's
            // parens (`return (x);` ends at `x`); those parens are the element's
            var xs = self._grow_start(st, en)
            // `eval if` / `eval for`: the statement's range starts at its
            // second keyword
            var ev = self._sig_before(xs)
            if self._kind_at(ev) == TokenKind::KwEval
                && self._line(self.toks[ev].start) == self._line(xs) {
                xs = self.toks[ev].start
            }

            en = self._grow_end(xs, self._code_end(xs, en))
            st = xs
            if st < cur {
                continue
            }

            // an import the parser kept as a node: _between prints it (section 5)
            if self._import_at(st) >= 0 {
                continue
            }

            self._between(cur, st, opener, unsafe &es, &r)

            var e    = Entry{}
            var core = self._core_end(st, en)
            e.semi = self._has_sep(st, en, TokenKind::OpSemicolon)
            if verb {
                e.doc = self._v(st, core)
            } else {
                self._entry(el, st, en, core, unsafe &e)
            }

            e.first = self._line(st)
            e.last  = self._line(en - 1)

            cur         = self._skip_seps(en)
            cur         = self._trailing(cur, hi, &e)
            e.next_kind = self._kind_at(self._sig_after(cur))

            es.push_back(e)
            done = en
        }

        self._between(cur, hi, opener, unsafe &es, &r)
        r.empty = es.empty()
        r.body  = self._layout(unsafe &es)
        self._oneline_members(unsafe &es, &r)
        return r
    }

    /// A comment on the element's last line trails it (rule 12.4). Returns
    /// the position past it, or \p cur.
    priv fn _trailing(self, cur: u32, hi: u32, e: *Entry) -> u32 {
        var j = self._lb(cur)
        while j < self.toks.size() && self.toks[j].kind == TokenKind::TkWhitespace {
            j += 1
        }

        if j >= self.toks.size() || self.toks[j].kind != TokenKind::AtComment {
            return cur
        }

        var c = self.toks[j]
        if self._line(c.start) != e->last || self._line(c.end - 1) != e->last || c.end > hi {
            return cur
        }

        e->cmt = self._text(c.start, c.end)
        // one line in the source: on its first line whatever it becomes
        e->cmt_first = e->first == e->last
        return c.end
    }

    /// Comments, imports and uncovered code in [a, b).
    priv fn _between(self,
                     a:      u32,
                     b:      u32,
                     opener: usize,
                     es:     unsafe *cxx::std::vector<Entry>,
                     r:      *ListOut) {
        var n       = self.toks.size()
        var i       = self._lb(a)
        var on      = false
        var g0: u32 = 0
        var g1: u32 = 0

        while i < n && self.toks[i].start < b {
            var t = self.toks[i]
            i += 1

            if t.kind == TokenKind::TkNewLine || t.kind == TokenKind::TkWhitespace {
                continue
            }

            if t.kind == TokenKind::AtComment {
                var cl = self._line(t.start)
                var ce = self._line(t.end - 1)

                if on {
                    // on the gap's last line: trails the gap
                    if cl == self._line(g1 - 1) && cl == ce {
                        self._gap(g0, g1, es, self._text(t.start, t.end))
                        on = false
                        continue
                    }

                    self._gap(g0, g1, es, "")
                    on = false
                }

                if es->empty() && opener != 0 && cl == opener && cl == ce && r->head.is_empty() {
                    r->head = Doc::line_suffix(
                        Doc::text(" " + self._text(t.start, t.end)),
                    )

                    continue
                }

                var e = Entry{}
                e.doc        = self._v(t.start, t.end)
                e.first      = cl
                e.last       = ce
                e.is_comment = true
                es->push_back(e)
                continue
            }

            // an import statement: an element of its own (section 5)
            var ix = self._import_at(t.start)
            if ix >= 0 && self.imps[ix as usize].end <= b {
                if on {
                    self._gap(g0, g1, es, "")
                    on = false
                }

                {
                    var im = self.imps[ix as usize]
                    var e  = Entry{}
                    e.doc   = self._import_doc(ix as usize)
                    e.imp   = ix
                    e.semi  = im.semi
                    e.first = self._line(im.start)
                    e.last  = self._line(im.end - 1)
                    var cur = self._trailing(im.end, b, &e)
                    e.cmt_first = false // after the import's last line, as import_lint writes it
                    e.next_kind = self._kind_at(self._sig_after(cur))
                    es->push_back(e)
                    i = self._lb(cur)
                    continue
                }
            }

            if !on && (t.kind == TokenKind::OpSemicolon || t.kind == TokenKind::OpComma) {
                continue
            }

            if !on {
                g0 = self._prefix_start(t.start)
                if g0 < a {
                    g0 = t.start
                }

                on = true
            }

            g1 = t.end
        }

        if on {
            self._gap(g0, g1, es, "")
        }
    }

    priv fn _gap(self, a: u32, b: u32, es: unsafe *cxx::std::vector<Entry>, cmt: string) {
        var e = Entry{}
        e.doc       = self._v(a, b)
        e.first     = self._line(a)
        e.last      = self._line(b - 1)
        e.cmt       = cmt
        e.next_kind = self._kind_at(self._sig_after(b))
        es->push_back(e)
    }

    /// The `;` an entry keeps (rule 13.1): only when the next line would
    /// otherwise continue its statement.
    priv fn _semi_of(self, e: *Entry) -> string {
        if e->semi && continues_statement(e->next_kind) {
            return ";"
        }

        return ""
    }

    /// An entry printed on its own: its doc, its kept `;`, its comment.
    priv fn _entry_doc(self, e: *Entry) -> Doc {
        var d = Doc::concat2(e->doc, Doc::text(self._semi_of(e)))
        if e->cmt.size() == 0 {
            return d
        }

        var s = Doc::line_suffix(Doc::text(" " + e->cmt))
        if e->cmt_first {
            return Doc::concat2(s, d)
        }

        return Doc::concat2(d, s)
    }

    priv fn _blank_lines(self, parts: unsafe *cxx::std::vector<Doc>, prev: usize, next: usize) {
        if next <= prev + 1 {
            return
        }

        var blank = next - prev - 1
        if blank > max_blank_lines() {
            blank = max_blank_lines()
        }

        for var b: usize = 0; b < blank; ++b {
            parts->push_back(Doc::hardline())
        }
    }

    priv fn _layout(self, es: unsafe *cxx::std::vector<Entry>) -> Doc {
        var parts       = cxx::std::vector<Doc>()
        var n           = es->size()
        var i:    usize = 0

        while i < n {
            if i > 0 {
                var *p = &(*es)[i - 1]
                var *q = &(*es)[i]
                // rule 3: the clause goes on the `}` line before it
                // (a trailing comment on the arm's first line stays there; one
                // on its `}` line would end up after the chained clause)
                if rules().chain_clauses
                    && p->chain_from
                    && q->chain_to
                    && (p->cmt.size() == 0 || p->cmt_first)
                    && !p->is_comment
                    && self._semi_of(p).size() == 0 {
                    parts.push_back(Doc::text(" "))
                    parts.push_back(self._entry_doc(q))
                    i += 1
                    continue
                }

                if rules().blank_after_closer && q->first <= p->last + 1 {
                    // rule 14.4: the renderer adds the blank
                    // line when the line this ends holds only closers
                    parts.push_back(Doc::gap_line())
                } else {
                    parts.push_back(Doc::hardline())
                    self._blank_lines(unsafe &parts, p->last, q->first)
                }
            }

            var j = self._import_run(es, i)
            if j > i {
                parts.push_back(self._import_block(es, i, j))
                i = j
                continue
            }

            j = self._run(es, i)
            if j > i + 1 {
                parts.push_back(self._row_table(es, i, j))
                i = j
                continue
            }

            j = self._comment_run(es, i)
            if j > i + 1 {
                parts.push_back(self._comment_table(es, i, j))
                i = j
                continue
            }

            parts.push_back(self._entry_doc(&(*es)[i]))
            i += 1
        }

        return Doc::concat(parts)
    }

    // ----------------------------------------------------------------------
    //  Import runs (5.3, 5.4)
    // ----------------------------------------------------------------------

    /// Past the import run starting at \p i, or \p i. A run is imports with
    /// only blank lines and comments between them; a comment belongs to the
    /// run only when it sits directly above an import of it (no blank line),
    /// so a comment the run would carry off is never orphaned: it ends the
    /// run instead.
    priv fn _import_run(self, es: unsafe *cxx::std::vector<Entry>, i: usize) -> usize {
        var n   = es->size()
        var j   = i
        var end = i
        while j < n {
            var *e = &(*es)[j]
            if e->imp >= 0 {
                if self.imps[e->imp as usize].raw {
                    break
                }

                if j > i && rules().import_blank_barrier && e->first > (*es)[j - 1].last + 1 {
                    break
                }

                j += 1
                end = j
                continue
            }

            if !e->is_comment {
                break
            }

            // a comment chain directly above an import, or the run ends
            var k = j
            while k < n
                && (*es)[k].is_comment
                && (k == j || (*es)[k].first <= (*es)[k - 1].last + 1) {
                k += 1
            }

            if k >= n || ((*es)[k].imp < 0) || (*es)[k].first > (*es)[k - 1].last + 1 {
                break
            }

            if j > i && rules().import_blank_barrier && (*es)[j].first > (*es)[j - 1].last + 1 {
                break
            }

            j = k
        }

        // a run must hold an import, and start at one or at its lead comments
        if end == i {
            return i
        }

        return end
    }

    /// The run [i, j) rebuilt: ffi imports first in their order, one blank
    /// line, then the Kairo imports sorted (Scripts/import_lint.py's layout).
    /// Comment lines directly above an import travel with it.
    priv fn _import_block(self, es: unsafe *cxx::std::vector<Entry>, i: usize, j: usize) -> Doc {
        var ffis = cxx::std::vector<usize>() // import entry indices
        var kai  = cxx::std::vector<usize>()
        var lead = cxx::std::vector<usize>() // per entry: index of its first lead comment
        for var k = i; k < j; ++k {
            lead.push_back(k)
        }

        var k = i
        while k < j {
            var s = k
            while (*es)[k].imp < 0 {
                k += 1
            }

            lead[k - i] = s
            if self.imps[(*es)[k].imp as usize].is_ffi {
                ffis.push_back(k)
            } else {
                kai.push_back(k)
            }

            k += 1
        }

        // stable sort of the Kairo imports by key
        var keys = cxx::std::vector<string>()
        for var x: usize = 0; x < kai.size(); ++x {
            keys.push_back(
                self.import_key(self.imps[(*es)[kai[x]].imp as usize]),
            )
        }

        for var x: usize = 1; x < kai.size(); ++x {
            var y = x
            while y > 0 && keys[y] < keys[y - 1] {
                var tk = keys[y]
                keys[y]     = keys[y - 1]
                keys[y - 1] = tk
                var ti = kai[y]
                kai[y]     = kai[y - 1]
                kai[y - 1] = ti
                y -= 1
            }
        }

        var parts = cxx::std::vector<Doc>()
        var first = true
        for var x: usize = 0; x < ffis.size(); ++x {
            self._import_unit(
                es,
                lead[ffis[x] - i],
                ffis[x],
                unsafe &parts,
                first,
            )

            first = false
        }

        if !ffis.empty() && !kai.empty() {
            parts.push_back(Doc::hardline())
        }

        for var x: usize = 0; x < kai.size(); ++x {
            self._import_unit(
                es,
                lead[kai[x] - i],
                kai[x],
                unsafe &parts,
                first,
            )

            first = false
        }

        return Doc::concat(parts)
    }

    priv fn _import_unit(self,
                         es:    unsafe *cxx::std::vector<Entry>,
                         from:  usize,
                         at:    usize,
                         parts: unsafe *cxx::std::vector<Doc>,
                         first: bool) {
        for var k = from; k <= at; ++k {
            if !first || k > from {
                parts->push_back(Doc::hardline())
            }

            parts->push_back(self._entry_doc(&(*es)[k]))
        }
    }

    // ----------------------------------------------------------------------
    //  Alignment runs (section 11)
    // ----------------------------------------------------------------------

    priv fn _row_kind(self, e: *Entry) -> u8 {
        if e->row == ROW_UNTYPED() && rules().decl_eq_column {
            return ROW_DECL()
        }

        return e->row
    }

    /// Width of an entry's row unpadded: its cells, separators and `;`.
    priv fn _row_width(self, e: *Entry) -> i32 {
        var w:   i32 = 0
        var seps     = Formatter::_row_seps()
        for var k: usize = 0; k < ROW_COLS(); ++k {
            var *c = &e->cells[k]
            if c->is_empty() {
                continue
            }

            if w > 0 {
                w += width_of(seps[k])
            }

            w += Renderer::flat_width(unsafe (c as unsafe *Doc))
        }

        return w + width_of(self._semi_of(e))
    }

    priv static fn _row_seps() -> cxx::std::vector<string> {
        var s = cxx::std::vector<string>()
        s.push_back("")
        s.push_back(" ")
        s.push_back(" ")
        s.push_back(" = ")
        s.push_back(" ") // a trailing comment (11.4)
        return s
    }

    priv fn _room(self) -> i32 {
        var lc = if self.set.use_tabs => self.set.tab_size * self.set.tab_size
                 else => self.set.tab_size
        return line_width() - self._depth * lc
    }

    /// Past the end of the alignment run starting at \p i (rules 11.1, 11.2,
    /// 7.4). A run is one-line rows of one kind on consecutive source lines,
    /// each of which fits flat; then trimmed so every row also fits padded.
    priv fn _run(self, es: unsafe *cxx::std::vector<Entry>, i: usize) -> usize {
        if !self.set.align {
            return i
        }

        var n    = es->size()
        var kind = self._row_kind(&(*es)[i])
        if kind == ROW_NONE() {
            return i
        }

        var room = self._room()
        var j    = i
        while j < n {
            var *e = &(*es)[j]
            if e->is_comment || self._row_kind(e) != kind {
                break
            }

            if j > i && e->first > (*es)[j - 1].last + 1 {
                break
            }

            if self._row_width(e) > room {
                break
            }

            // a call row over the call limit is printed broken, ending in a
            // `)` line that rule 14.4 follows with a blank line: the run
            // must end before it, or the next pass, which sees that blank
            // line, would cut the run elsewhere
            if e->capped && self._row_width(e) > self.set.call_width - (line_width() - room) {
                break
            }

            j += 1
        }

        // every row padded must still fit, a call row by call_width (4.1)
        while j > i + 1 {
            var w   = self._col_widths(es, i, j)
            var bad = j
            for var r = i; r < j; ++r {
                var *e  = &(*es)[r]
                var lim = room
                if e->capped {
                    lim = self.set.call_width - (line_width() - room)
                }

                if self._padded_width(e, unsafe &w) > lim {
                    bad = r
                    break
                }
            }

            if bad == j {
                break
            }

            if bad <= i + 1 {
                return i
            }

            j = bad
        }

        return j
    }

    priv fn _col_widths(self,
                        es: unsafe *cxx::std::vector<Entry>,
                        i:  usize,
                        j:  usize) -> cxx::std::vector<i32> {
        var w = cxx::std::vector<i32>()
        for var k: usize = 0; k < ROW_COLS(); ++k {
            w.push_back(0)
        }

        for var r = i; r < j; ++r {
            for var k: usize = 0; k < ROW_COLS(); ++k {
                var cw = Renderer::flat_width(unsafe &(*es)[r].cells[k])
                if cw > w[k] {
                    w[k] = cw
                }
            }
        }

        return w
    }

    /// The row's width once its columns are padded to \p w, up to its value.
    priv fn _padded_width(self, e: *Entry, w: unsafe *cxx::std::vector<i32>) -> i32 {
        var seps        = Formatter::_row_seps()
        var last: usize = 0
        for var k: usize = 0; k < ROW_COLS(); ++k {
            if !e->cells[k].is_empty() {
                last = k
            }
        }

        var t: i32 = 0
        for var k: usize = 0; k <= last; ++k {
            if k > 0 && (*w)[k] > 0 {
                t += width_of(seps[k])
            }

            if k < last {
                t += (*w)[k]
            } else {
                t += Renderer::flat_width(unsafe &e->cells[k])
            }
        }

        return t + width_of(self._semi_of(e))
    }

    priv fn _row_table(self, es: unsafe *cxx::std::vector<Entry>, i: usize, j: usize) -> Doc {
        var cells = cxx::std::vector<Doc>()
        var cmts  = self._aligned_comments(es, i, j)
        for var r = i; r < j; ++r {
            var *e          = &(*es)[r]
            var semi        = self._semi_of(e)
            var last: usize = 0
            for var k: usize = 0; k < ROW_COLS(); ++k {
                if !e->cells[k].is_empty() {
                    last = k
                }
            }

            for var k: usize = 0; k < ROW_COLS(); ++k {
                var c = e->cells[k]
                if k == last {
                    c = Doc::concat2(c, Doc::text(semi))
                    if !cmts && e->cmt.size() > 0 {
                        c = Doc::concat2(
                            c,
                            Doc::line_suffix(Doc::text(" " + e->cmt)),
                        )
                    }
                }

                cells.push_back(c)
            }

            if cmts && e->cmt.size() > 0 {
                cells.push_back(Doc::text(e->cmt))
            } else {
                cells.push_back(Doc::nothing())
            }
        }

        return Doc::table(
            cells,
            (ROW_COLS() + 1) as i32,
            Formatter::_row_seps(),
        )
    }

    /// Rule 11.4 inside a row run: align the trailing comments when every
    /// row with one still fits the width with it.
    priv fn _aligned_comments(self,
                              es: unsafe *cxx::std::vector<Entry>,
                              i:  usize,
                              j:  usize) -> bool {
        if !rules().align_trailing_comments {
            return false
        }

        var any         = false
        var w           = self._col_widths(es, i, j)
        var widest: i32 = 0
        for var r = i; r < j; ++r {
            var pw = self._padded_width(&(*es)[r], unsafe &w)
            if pw > widest {
                widest = pw
            }

            if (*es)[r].cmt.size() > 0 {
                any = true
            }
        }

        if !any {
            return false
        }

        for var r = i; r < j; ++r {
            var c = (*es)[r].cmt
            if c.size() > 0 && widest + 1 + width_of(c) > self._room() {
                return false
            }
        }

        return true
    }

    /// Rule 11.4 outside row runs: past the end of a run of one-line entries
    /// on consecutive lines, each ending with a trailing comment.
    priv fn _comment_run(self, es: unsafe *cxx::std::vector<Entry>, i: usize) -> usize {
        if !self.set.align || !rules().align_trailing_comments {
            return i
        }

        var n           = es->size()
        var room        = self._room()
        var widest: i32 = 0
        var j           = i
        while j < n {
            var *e = &(*es)[j]
            if e->is_comment || e->imp >= 0 || e->cmt.size() == 0 {
                break
            }

            if j > i && e->first > (*es)[j - 1].last + 1 {
                break
            }

            var w = Renderer::flat_width(unsafe &e->doc) + width_of(
                self._semi_of(e),
            )

            if w >= Renderer::unfittable() || w > room {
                break
            }

            if e->capped && w > self.set.call_width - (line_width() - room) {
                break
            }

            if w > widest {
                widest = w
            }

            j += 1
        }

        if j <= i + 1 {
            return i
        }

        for var r = i; r < j; ++r {
            if widest + 1 + width_of((*es)[r].cmt) > room {
                return i
            }
        }

        return j
    }

    priv fn _comment_table(self, es: unsafe *cxx::std::vector<Entry>, i: usize, j: usize) -> Doc {
        var cells = cxx::std::vector<Doc>()
        for var r = i; r < j; ++r {
            var *e = &(*es)[r]
            cells.push_back(Doc::concat2(e->doc, Doc::text(self._semi_of(e))))
            cells.push_back(Doc::text(e->cmt))
        }

        var seps = cxx::std::vector<string>()
        seps.push_back("")
        seps.push_back(" ")
        return Doc::table(cells, 2, seps)
    }

    // ----------------------------------------------------------------------
    //  One-line type bodies (7.5)
    // ----------------------------------------------------------------------

    /// The members of a body written on one line, joined on one line, when
    /// every member is a one-line field or variant with no comment.
    priv fn _oneline_members(self, es: unsafe *cxx::std::vector<Entry>, r: *ListOut) {
        if es->empty() {
            return
        }

        var parts = cxx::std::vector<Doc>()
        for var i: usize = 0; i < es->size(); ++i {
            var *e = &(*es)[i]
            if !e->member || e->cmt.size() > 0 || e->doc.hard {
                return
            }

            if i > 0 {
                // fields on one line are separated by `;` (13.2: required there);
                // enum variants carry their own `,`, as written
                if !(*es)[i - 1].variant {
                    parts.push_back(Doc::text(";"))
                }

                parts.push_back(Doc::text(" "))
            }

            parts.push_back(e->doc)
        }

        r->oneline     = Doc::concat(parts)
        r->can_oneline = true
    }

    priv fn _entry(self, el: Elem, st: u32, en: u32, core: u32, e: unsafe *Entry) {
        if el.decl != &null {
            e->doc = self._decl(el.decl, st, core, e)
            e->member = (isa<FieldDecl>(el.decl) || isa<VariableDecl>(el.decl))
                && (e->row == ROW_DECL() || e->row == ROW_UNTYPED())
            return
        }

        if el.stmt != &null {
            self._blk_broken = false
            e->doc           = self._stmt(el.stmt, st, core, e)
            // rule 8.11: `} finally {` after a statement `try`
            e->chain_from = isa<TryCatchStmt>(el.stmt) && self._blk_broken
            e->chain_to   = isa<FinallyStmt>(el.stmt)
            return
        }

        if el.expr != &null {
            e->doc = self.fx(el.expr, true)
            return
        }

        if el.variant != &null {
            e->semi    = false
            e->member  = true
            e->variant = true
            if self._has_sep(st, en, TokenKind::OpComma) {
                e->sep = ","
            }

            e->doc = self._variant(el.variant, st, core, e)
            return
        }

        if el.mcase != &null {
            self._blk_broken = false
            e->doc           = self._case(el.mcase, st, core)
            // rule 8.4: `} case B {` / `} default {`
            e->chain_from = el.mcase->body != &null && self._blk_broken
            e->chain_to   = el.mcase->body != &null
            return
        }

        e->doc = self._v(st, core)
    }

    // ----------------------------------------------------------------------
    //  Blocks
    // ----------------------------------------------------------------------

    /// `{ ... }`. A block written on one line holding one simple statement
    /// stays on one line while it fits (rule 8.1).
    priv fn _block(self, b: unsafe *CompoundStmt) -> Doc {
        var ungroup = self._ungroup_next
        self._ungroup_next = false
        var a = b->range.start.raw()
        var z = b->range.end.raw()
        var o = self._sig_after(a)
        var c = self._sig_before(z)
        self._blk_broken = false
        if self._kind_at(o) != TokenKind::OpLBrace
            || self._kind_at(c) != TokenKind::OpRBrace
            || o >= c {
            return self._v(a, z)
        }

        var lo = self.toks[o].end
        var hi = self.toks[c].start

        if b->body.is_empty() && !self._comment_in(lo, hi) && !self._has_sig(lo, hi) {
            return Doc::text("{ }")
        }

        // rule 8.1: under blocks_always_break no block stays
        // on one line
        if !rules().blocks_always_break
            && self._line(a) == self._line(z - 1)
            && b->body.size() == 1
            && !self._comment_in(lo, hi)
            && !self._is_block_stmt(b->body[0])
            && !self._macro_in(lo, hi) {
            var unsafe *s0 = b->body[0]
            var        sa  = s0->range.start.raw()
            var        se  = s0->range.end.raw()
            // the one statement's `;` is redundant before the `}` (13.1)
            var sd = self._stmt(s0, sa, self._core_end(sa, se), &null)
            var one = Doc::concat3(
                Doc::text("{"),
                Doc::indent(Doc::concat2(Doc::line(), sd)),
                Doc::concat2(Doc::line(), Doc::text("}")),
            )

            if ungroup {
                return one
            }

            return Doc::group(one)
        }

        var els = cxx::std::vector<Elem>()
        for var i: usize = 0; i < b->body.size(); ++i {
            self._push_stmt(b->body[i], unsafe &els)
        }

        var d = self._braced(
            Doc::nothing(),
            lo,
            hi,
            self._line(self.toks[o].start),
            unsafe &els,
            false,
        )

        // read after _braced: the blocks nested in it set the flag too
        self._blk_broken = !self._braced_empty
        return d
    }

    /// \p head ` {` members `}`. \p oneline: a type body written on one line
    /// (7.5), which stays on one line while it fits.
    priv fn _braced(self,
                    head:    Doc,
                    lo:      u32,
                    hi:      u32,
                    opener:  usize,
                    els:     unsafe *cxx::std::vector<Elem>,
                    oneline: bool) -> Doc {
        self._depth += 1
        var l = self._list(lo, hi, opener, els)
        self._depth -= 1

        var open = if head.is_empty() => Doc::text("{") else => Doc::concat2(head, Doc::text(" {"))
        self._braced_empty = l.empty && l.head.is_empty()
        if self._braced_empty {
            return Doc::concat2(open, Doc::text(" }"))
        }

        var broken = Doc::concat5(
            open,
            l.head,
            Doc::indent(Doc::concat2(Doc::hardline(), l.body)),
            Doc::hardline(),
            Doc::text("}"),
        )

        if oneline && l.can_oneline && l.head.is_empty() && rules().oneline_type_bodies {
            var flat = Doc::concat3(
                open,
                Doc::text(" "),
                Doc::concat2(l.oneline, Doc::text(" }")),
            )

            // the one-line form, unless it overflows: then the broken one
            if !flat.hard {
                return Doc::choice(flat, broken)
            }
        }

        return broken
    }

    /// Header as written, then a formatted block.
    priv fn _hb(self, a: u32, blk: unsafe *CompoundStmt) -> Doc {
        if blk == &null {
            return Doc::nothing()
        }

        var h = self._span(a, blk->range.start.raw())
        if h.is_empty() {
            return self._block(blk)
        }

        return Doc::concat3(h, Doc::text(" "), self._block(blk))
    }

    /// `kw cond {` with the condition laid out from the tree (rules 3.3,
    /// 8.2), when the header is exactly the keyword(s) and the condition;
    /// otherwise as written. \p a is where the header's text starts (after
    /// a previous block, for `else if`).
    priv fn _cond_hb(self,
                     a:    u32,
                     kw:   string,
                     cond: unsafe *Expr,
                     blk:  unsafe *CompoundStmt) -> Doc {
        if blk == &null {
            return Doc::nothing()
        }

        var bs = blk->range.start.raw()
        if !rules().respace_headers
            || cond == &null
            || self._comment_in(a, bs)
            || self._macro_in(a, bs) {
            return self._hb(a, blk)
        }

        var cs = self._es(cond)
        var ce = self._ee(cond)
        // the keywords, then the condition (its glued parens included), then `{`
        var lead = self._ext_parens(cs, ce)
        var p    = self._sig_before(self._lead_start(cs))
        var q    = self._sig_after(ce)
        for var x: u32 = 0; x < lead; ++x {
            q = self._sig_after(self.toks[q].end)
        }

        if q != self._sig_after(bs) || self._kind_at(q) != TokenKind::OpLBrace {
            return self._hb(a, blk)
        }

        var written = self._trimmed(
            a,
            if p < self.toks.size() => self.toks[p].end else => cs,
        )

        if !Formatter::_same_words(written, kw) {
            return self._hb(a, blk)
        }

        var c = self.fxc(cond, true, PCtx { kind: 4, prec: 0, right: false })
        return Doc::concat4(
            Doc::text(kw + " "),
            c,
            Doc::text(" "),
            self._block(blk),
        )
    }

    /// \p a equals \p b once runs of whitespace are one space.
    priv static fn _same_words(a: string, b: string) -> bool {
        var s: string = ""
        var sp        = false
        for var i: usize = 0; i < a.size(); ++i {
            if Formatter::_ws(a[i]) {
                sp = true
                continue
            }

            if sp && s.size() > 0 {
                s += " "
            }

            sp = false
            s.push_back(a[i])
        }

        return s == b
    }

    priv fn _is_block_stmt(self, s: unsafe *Stmt) -> bool {
        if s == &null {
            return false
        }

        if isa<DeclStmt>(s) {
            var unsafe *d = cast<DeclStmt>(s)->decl
            return d != &null && !isa<VariableDecl>(d)
        }

        return isa<CompoundStmt>(s)
            || isa<ConditionalStmt>(s)
            || isa<WhileLoopStmt>(s)
            || isa<LoopStmt>(s)
            || isa<RangedForStmt>(s)
            || isa<IndexedForStmt>(s)
            || isa<MatchStmt>(s)
            || isa<LabeledStmt>(s)
            || isa<TryCatchStmt>(s)
            || isa<FinallyStmt>(s)
            || isa<UnsafeBlockStmt>(s)
            || isa<ContextBindingStmt>(s)
    }

    // ----------------------------------------------------------------------
    //  Statements
    // ----------------------------------------------------------------------

    /// \p e, when given, is filled for alignment (section 11).
    priv fn _stmt(self, s: unsafe *Stmt, st: u32, en: u32, e: unsafe *Entry) -> Doc {
        if isa<CompoundStmt>(s) {
            return self._block(cast<CompoundStmt>(s))
        }

        if isa<ExpressionStmt>(s) {
            var unsafe *x = cast<ExpressionStmt>(s)->expr
            if e != &null
                && x != &null
                && isa<AssignOperatorExpr>(x)
                && !self._comment_in(st, en)
                && !self._macro_in(st, en)
                && !self._wrapped(x) {
                var unsafe *a = cast<AssignOperatorExpr>(x)
                if self._tok(a->op_token) == "=" {
                    var c0 = self._calls
                    var lhs = self.fxc(
                        a->lhs,
                        true,
                        PCtx { kind: 1, prec: 1, right: false },
                    )

                    var rhs = self.fxc(
                        a->rhs,
                        true,
                        PCtx { kind: 1, prec: 1, right: true },
                    )

                    self._fill_row(
                        e,
                        ROW_ASSIGN(),
                        lhs,
                        Doc::nothing(),
                        Doc::nothing(),
                        rhs,
                    )

                    e->capped = self._calls != c0
                    return Doc::concat3(lhs, Doc::text(" = "), rhs)
                }
            }

            if x == &null {
                return self._v(st, en)
            }

            return self.fx(x, true)
        }

        if isa<DeclStmt>(s) {
            return self._decl(cast<DeclStmt>(s)->decl, st, en, e)
        }

        if isa<ReturnStmt>(s) {
            var unsafe *v = cast<ReturnStmt>(s)->value
            if v == &null {
                return Doc::text("return")
            }

            if self._comment_in(st, v->range.start.raw()) {
                return self._v(st, en)
            }

            return Doc::concat2(Doc::text("return "), self.fx(v, true))
        }

        if isa<BreakStmt>(s) {
            var unsafe *b = cast<BreakStmt>(s)
            if !b->has_label {
                return Doc::text("break")
            }

            return Doc::text("break " + self._tok(b->label))
        }

        if isa<ContinueStmt>(s) {
            var unsafe *c = cast<ContinueStmt>(s)
            if !c->has_label {
                return Doc::text("continue")
            }

            return Doc::text("continue " + self._tok(c->label))
        }

        if isa<PanicStmt>(s) {
            var unsafe *p = cast<PanicStmt>(s)->payload
            if p == &null || self._comment_in(st, p->range.start.raw()) {
                return self._v(st, en)
            }

            return Doc::concat2(Doc::text("panic "), self.fx(p, true))
        }

        if isa<YieldStmt>(s) {
            var unsafe *y = cast<YieldStmt>(s)->value
            if y == &null || self._comment_in(st, y->range.start.raw()) {
                return self._v(st, en)
            }

            return Doc::concat2(Doc::text("yield "), self.fx(y, true))
        }

        if isa<ConditionalStmt>(s) {
            return self._if(cast<ConditionalStmt>(s), st, en)
        }

        if isa<WhileLoopStmt>(s) {
            var unsafe *w = cast<WhileLoopStmt>(s)
            return self._cond_hb(st, "while", w->cond, w->body)
        }

        if isa<LoopStmt>(s) {
            return self._hb(st, cast<LoopStmt>(s)->body)
        }

        if isa<RangedForStmt>(s) {
            return self._hb(st, cast<RangedForStmt>(s)->body)
        }

        if isa<IndexedForStmt>(s) {
            return self._hb(st, cast<IndexedForStmt>(s)->body)
        }

        if isa<FinallyStmt>(s) {
            return self._hb(st, cast<FinallyStmt>(s)->body)
        }

        if isa<UnsafeBlockStmt>(s) {
            return self._hb(st, cast<UnsafeBlockStmt>(s)->body)
        }

        if isa<ContextBindingStmt>(s) {
            return self._hb(st, cast<ContextBindingStmt>(s)->body)
        }

        if isa<MatchStmt>(s) {
            return self._match(cast<MatchStmt>(s), st, en)
        }

        if isa<TryCatchStmt>(s) {
            return self._try(cast<TryCatchStmt>(s), st, en)
        }

        if isa<LabeledStmt>(s) {
            var unsafe *l   = cast<LabeledStmt>(s)
            var unsafe *_in = l->inner
            if _in == &null {
                return self._v(st, en)
            }

            var ia = _in->range.start.raw()
            var ie = _in->range.end.raw()
            if self._comment_in(st, ia) {
                return self._v(st, en)
            }

            return Doc::concat2(
                Doc::text(self._tok(l->label) + ": "),
                self._stmt(_in, ia, self._core_end(ia, ie), &null),
            )
        }

        if isa<DestructuringDeclStmt>(s) {
            var unsafe *v = cast<DestructuringDeclStmt>(s)->value
            if v == &null || self._comment_in(st, v->range.start.raw()) {
                return self._v(st, en)
            }

            return Doc::concat3(
                self._span(st, self._lead_start(v->range.start.raw())),
                Doc::text(" "),
                self.fx(v, true),
            )
        }

        // asserts, label!/jump!, inline blocks (copied exactly), eval blocks, the rest
        return self._v(st, en)
    }

    /// `if`/`else if`/`else` chain. Each header is laid out from the tree
    /// when it is exactly `if cond` / `else if cond` (_cond_hb), else copied
    /// from the end of the previous block, so `eval` and attributes stay as
    /// written.
    priv fn _if(self, s: unsafe *ConditionalStmt, st: u32, en: u32) -> Doc {
        if s->then_ == &null {
            return self._v(st, en)
        }

        // an `if` with an `else` is laid out as one: every block on one line
        // while the whole chain fits, else every block broken (8.1, 8.2)
        var chain = s->else_ != &null && rules().if_chain_together

        self._ungroup_next = chain
        var d = if s->is_eval => self._hb(st, s->then_)
                else => self._cond_hb(st, "if", s->cond, s->then_)
        var unsafe *cur = s
        while cur->else_ != &null {
            var        prev = cur->then_->range.end.raw()
            var unsafe *el  = cur->else_

            if isa<ConditionalStmt>(el) {
                var unsafe *ec = cast<ConditionalStmt>(el)
                if ec->then_ == &null {
                    return self._v(st, en)
                }

                self._ungroup_next = chain
                var h = if ec->is_eval => self._hb(prev, ec->then_)
                        else => self._cond_hb(
                            prev,
                            "else if",
                            ec->cond,
                            ec->then_,
                        )

                d   = Doc::concat3(d, Doc::text(" "), h)
                cur = ec
                continue
            }

            if isa<CompoundStmt>(el) {
                self._ungroup_next = chain
                d = Doc::concat3(
                    d,
                    Doc::text(" "),
                    self._hb(prev, cast<CompoundStmt>(el)),
                )

                break
            }

            self._ungroup_next = false
            return self._v(st, en)
        }

        self._ungroup_next = false
        if chain {
            return Doc::group(d)
        }

        return d
    }

    priv fn _try(self, s: unsafe *TryCatchStmt, st: u32, en: u32) -> Doc {
        if s->try_body == &null {
            return self._v(st, en)
        }

        var d    = self._hb(st, s->try_body)
        var prev = s->try_body->range.end.raw()
        for var i: usize = 0; i < s->arms.size(); ++i {
            var unsafe *arm = s->arms.get(i)
            if arm->body == &null {
                self._blk_broken = false
                return self._v(st, en)
            }

            d    = Doc::concat3(d, Doc::text(" "), self._hb(prev, arm->body))
            prev = arm->body->range.end.raw()
        }

        return d
    }

    priv fn _match(self, s: unsafe *MatchStmt, st: u32, en: u32) -> Doc {
        if s->scrutinee == &null {
            return self._v(st, en)
        }

        var o = self._sig_after(s->scrutinee->range.end.raw())
        var c = self._sig_before(en)
        if self._kind_at(o) != TokenKind::OpLBrace
            || self._kind_at(c) != TokenKind::OpRBrace
            || o >= c {
            return self._v(st, en)
        }

        var els = cxx::std::vector<Elem>()
        for var i: usize = 0; i < s->cases.size(); ++i {
            var unsafe *mc = s->cases.get(i)
            if mc->range.is_invalid() {
                continue
            }

            els.push_back(
                Elem { start: mc->range.start.raw(), end: mc->range.end.raw(), mcase: mc },
            )
        }

        var        head = self._span(st, self.toks[o].start)
        var unsafe *sc  = s->scrutinee
        if rules().respace_headers
            && !self._comment_in(st, self.toks[o].start)
            && !self._macro_in(st, self.toks[o].start)
            && self._kind_at(self._sig_after(st)) == TokenKind::KwMatch
            && self._sig_after(self.toks[self._sig_after(st)].end) == self._sig_after(
                self._lead_start(sc->range.start.raw()),
            )
            && self._sig_after(sc->range.end.raw()) == o {
            head = Doc::concat2(
                Doc::text("match "),
                self.fxc(sc, false, PCtx { kind: 4, prec: 0, right: false }),
            )
        }

        return self._braced(
            head,
            self.toks[o].end,
            self.toks[c].start,
            self._line(self.toks[o].start),
            unsafe &els,
            false,
        )
    }

    priv fn _case(self, mc: unsafe *MatchCase, st: u32, en: u32) -> Doc {
        if mc->body == &null {
            if mc->expression != &null && self._case_grid_applies(mc) {
                var v = self._case_value(mc, st)
                if !v.is_empty() {
                    return v
                }
            }

            return self._v(st, en)
        }

        if self._case_grid_applies(mc) {
            var h = self._case_head(mc, st, mc->body->range.start.raw())
            if !h.is_empty() {
                return Doc::concat3(h, Doc::text(" "), self._block(mc->body))
            }
        }

        return self._hb(st, mc->body)
    }

    priv fn _case_grid_applies(self, mc: unsafe *MatchCase) -> bool {
        return rules().case_grid && !mc->is_default && mc->patterns.size() > case_grid_min()
    }

    /// Rule 8.4: `case` and its alternatives as a grid
    /// aligned under the first one, then whatever follows the last one up to
    /// \p b (a `where` guard) as written. Nothing when the header is not
    /// exactly `case p, p, ...`: a comment, a macro, a multi-line pattern, or
    /// anything but one `,` between two patterns.
    priv fn _case_head(self, mc: unsafe *MatchCase, st: u32, b: u32) -> Doc {
        var kc = self._sig_after(st)
        if self._kind_at(kc) != TokenKind::KwCase
            || self._comment_in(st, b)
            || self._macro_in(st, b) {
            return Doc::nothing()
        }

        var n     = mc->patterns.size()
        var keys  = cxx::std::vector<Doc>()
        var vals  = cxx::std::vector<Doc>()
        var prev  = self.toks[kc].end
        var first = true
        for var i: usize = 0; i < n; ++i {
            var unsafe *p = mc->patterns[i]
            if p == &null || p->range.is_invalid() {
                return Doc::nothing()
            }

            var ps = p->range.start.raw()
            var pe = self._code_end(ps, p->range.end.raw())
            if pe <= ps || self._line(ps) != self._line(pe - 1) || ps < prev {
                return Doc::nothing()
            }

            // between the previous part and this pattern: nothing, or one `,`
            var f = self._sig_after(prev)
            if !first {
                if self._kind_at(f) != TokenKind::OpComma {
                    return Doc::nothing()
                }

                f = self._sig_after(self.toks[f].end)
            }

            if f >= self.toks.size() || self.toks[f].start != ps {
                return Doc::nothing()
            }

            keys.push_back(Doc::nothing())
            vals.push_back(self._v(ps, pe))
            prev  = pe
            first = false
        }

        var tail  = self._span(prev, b)
        var parts = cxx::std::vector<Doc>()
        parts.push_back(Doc::text("case "))
        parts.push_back(
            Doc::list(
                "",
                "",
                keys,
                vals,
                Doc::nothing(),
                LIST_CASEGRID() | LIST_FORCE(),
            ),
        )

        if !tail.is_empty() {
            parts.push_back(Doc::text(" "))
            parts.push_back(tail)
        }

        return Doc::concat(parts)
    }

    /// A value arm `case p => v` laid out: the header (a grid under rule
    /// 6) up to the `=>`, then the value from the tree. Nothing when the
    /// arm is not exactly that.
    priv fn _case_value(self, mc: unsafe *MatchCase, st: u32) -> Doc {
        var unsafe *v = mc->expression
        if v == &null {
            return Doc::nothing()
        }

        var vs = self._es(v)
        var ar = self._sig_before(vs)
        var np = self._ext_parens(vs, self._ee(v))
        for var k: u32 = 0; k < np; ++k {
            ar = self._sig_before(self.toks[ar].start)
        }

        if self._kind_at(ar) != TokenKind::OpFatArrow || self.toks[ar].start <= st {
            return Doc::nothing()
        }

        var head = Doc::nothing()
        if self._case_grid_applies(mc) {
            head = self._case_head(mc, st, self.toks[ar].start)
        }

        if head.is_empty() {
            if self._comment_in(st, self.toks[ar].start) {
                return Doc::nothing()
            }

            head = self._span(st, self.toks[ar].start)
        }

        if head.is_empty() {
            return Doc::nothing()
        }

        return Doc::concat3(
            head,
            Doc::text(" => "),
            self.fxc(v, true, PCtx { kind: 4, prec: 0, right: false }),
        )
    }

    // ----------------------------------------------------------------------
    //  Declarations
    // ----------------------------------------------------------------------

    priv fn _decl(self, d: unsafe *Decl, st: u32, en: u32, e: unsafe *Entry) -> Doc {
        if d == &null {
            return self._v(st, en)
        }

        if isa<VariableDecl>(d) {
            var unsafe *v = cast<VariableDecl>(d)
            return self._var(st, en, v->type_, v->init, e)
        }

        if isa<FieldDecl>(d) {
            var unsafe *f = cast<FieldDecl>(d)
            return self._var(st, en, f->type_, f->init, e)
        }

        if isa<FunctionDecl>(d) {
            return self._fn(cast<FunctionDecl>(d), st, en)
        }

        if isa<TestDecl>(d) {
            var unsafe *t = cast<TestDecl>(d)
            if t->body == &null {
                return self._v(st, en)
            }

            return self._hb(st, t->body)
        }

        if isa<ProcedureMacroDecl>(d) {
            var unsafe *p = cast<ProcedureMacroDecl>(d)
            if p->body == &null {
                return self._v(st, en)
            }

            return self._hb(st, p->body)
        }

        var els = cxx::std::vector<Elem>()
        if isa<ClassDecl>(d) {
            var unsafe *c = cast<ClassDecl>(d)
            for var i: usize = 0; i < c->fields.size(); ++i {
                self._push_decl(c->fields[i], unsafe &els)
            }

            for var i: usize = 0; i < c->methods.size(); ++i {
                self._push_decl(c->methods[i], unsafe &els)
            }

            self._push_dc(unsafe (c as unsafe *DeclContext), unsafe &els)
            return self._aggregate(st, en, unsafe &els, true)
        }

        if isa<StructDecl>(d) {
            var unsafe *s = cast<StructDecl>(d)
            for var i: usize = 0; i < s->fields.size(); ++i {
                self._push_decl(s->fields[i], unsafe &els)
            }

            for var i: usize = 0; i < s->methods.size(); ++i {
                self._push_decl(s->methods[i], unsafe &els)
            }

            self._push_dc(unsafe (s as unsafe *DeclContext), unsafe &els)
            return self._aggregate(st, en, unsafe &els, true)
        }

        if isa<UnionDecl>(d) {
            var unsafe *u = cast<UnionDecl>(d)
            for var i: usize = 0; i < u->fields.size(); ++i {
                self._push_decl(u->fields[i], unsafe &els)
            }

            for var i: usize = 0; i < u->methods.size(); ++i {
                self._push_decl(u->methods[i], unsafe &els)
            }

            self._push_dc(unsafe (u as unsafe *DeclContext), unsafe &els)
            return self._aggregate(st, en, unsafe &els, true)
        }

        if isa<InterfaceDecl>(d) {
            var unsafe *it = cast<InterfaceDecl>(d)
            for var i: usize = 0; i < it->methods.size(); ++i {
                self._push_decl(it->methods[i], unsafe &els)
            }

            self._push_dc(unsafe (it as unsafe *DeclContext), unsafe &els)
            return self._aggregate(st, en, unsafe &els, false)
        }

        if isa<ExtensionDecl>(d) {
            var unsafe *x = cast<ExtensionDecl>(d)
            for var i: usize = 0; i < x->methods.size(); ++i {
                self._push_decl(x->methods[i], unsafe &els)
            }

            self._push_dc(unsafe (x as unsafe *DeclContext), unsafe &els)
            return self._aggregate(st, en, unsafe &els, false)
        }

        if isa<EnumDecl>(d) {
            var unsafe *en_ = cast<EnumDecl>(d)
            for var i: usize = 0; i < en_->variants.size(); ++i {
                var unsafe *v = en_->variants[i]
                if v == &null || v->range.is_invalid() {
                    continue
                }

                els.push_back(
                    Elem { start: self._decl_start(v), end: v->range.end.raw(), variant: v },
                )
            }

            self._push_dc(unsafe (en_ as unsafe *DeclContext), unsafe &els)
            return self._aggregate(st, en, unsafe &els, true)
        }

        if isa<ModuleDecl>(d) {
            self._push_dc(
                unsafe (cast<ModuleDecl>(d) as unsafe *DeclContext),
                unsafe &els,
            )

            return self._aggregate(st, en, unsafe &els, false)
        }

        if isa<VisibilityGroupDecl>(d) {
            var unsafe *g = cast<VisibilityGroupDecl>(d)
            for var i: usize = 0; i < g->members.size(); ++i {
                self._push_decl(g->members[i], unsafe &els)
            }

            return self._aggregate(st, en, unsafe &els, false)
        }

        if isa<FFIBlockDecl>(d) {
            var unsafe *fb = cast<FFIBlockDecl>(d)
            for var i: usize = 0; i < fb->body.size(); ++i {
                self._push_decl(fb->body[i], unsafe &els)
            }

            return self._aggregate(st, en, unsafe &els, false)
        }

        // type aliases, macro decls, eval blocks: as written
        return self._v(st, en)
    }

    priv fn _fill_row(self, e: unsafe *Entry, kind: u8, c0: Doc, c1: Doc, c2: Doc, c3: Doc) {
        if e == &null {
            return
        }

        e->row = kind
        e->cells.clear()
        e->cells.push_back(c0)
        e->cells.push_back(c1)
        e->cells.push_back(c2)
        e->cells.push_back(c3)
    }

    /// `var`/`const`/field. Rule 11.2 columns: everything before the name,
    /// `name:` (the `:` glued, 6.7), the type, the initializer.
    priv fn _var(self,
                 st:   u32,
                 en:   u32,
                 ty:   unsafe *Type,
                 init: unsafe *Expr,
                 e:    unsafe *Entry) -> Doc {
        if self._comment_in(st, en) || ty == &null && init == &null {
            return self._v(st, en)
        }

        // the `:` (typed) or `=` (untyped) after the name. A type's range can
        // start after a leading qualifier (`unsafe *T` starts at `*`), so the
        // `:` is the first one outside brackets, not the token before the type
        var k = self.toks.size()
        if ty != &null {
            k = self._top_colon(st, ty->range.start.raw() + 1)
        } else {
            k = self._sig_before(self._lead_start(init->range.start.raw()))
            if self._kind_at(k) != TokenKind::OpEqual {
                return self._v(st, en)
            }
        }

        if k >= self.toks.size() {
            return self._v(st, en)
        }

        // the name: the one token before the `:` / `=`
        var nm = self._sig_before(self.toks[k].start)
        if nm >= self.toks.size() || self.toks[nm].start < st {
            return self._v(st, en)
        }

        // tokens glued to the name belong to its cell (`var unsafe *x`: the
        // name cell is `*x`)
        var ns = nm
        while ns > 0 {
            var pv = self._sig_before(self.toks[ns].start)
            if pv >= self.toks.size()
                || self.toks[pv].start < st
                || self.toks[pv].end != self.toks[ns].start {
                break
            }

            ns = pv
        }

        var name = self._text(self.toks[ns].start, self.toks[nm].end)
        var kw   = self._span(st, self.toks[ns].start)
        if kw.hard {
            return self._v(st, en)
        }

        var c0 = self._calls
        if ty != &null {
            var te = self._type_end(ty)
            if te <= self.toks[k].end {
                return self._v(st, en)
            }

            var tyd = self._span(self.toks[k].end, te)
            var ini = Doc::nothing()
            if init != &null {
                var eq = self._sig_after(te)
                if self._kind_at(eq) != TokenKind::OpEqual
                    || self._sig_after(self.toks[eq].end) != self._sig_after(
                        self._lead_start(init->range.start.raw()),
                    ) {
                    return self._v(st, en)
                }

                ini = self.fx(init, true)
            }

            if init != &null && !rules().decl_eq_column {
                // no `=` column: the initializer rides in the type cell
                self._fill_row(
                    e,
                    ROW_DECL(),
                    kw,
                    Doc::text(name + ":"),
                    Doc::concat3(tyd, Doc::text(" = "), ini),
                    Doc::nothing(),
                )
            } else {
                self._fill_row(
                    e,
                    ROW_DECL(),
                    kw,
                    Doc::text(name + ":"),
                    tyd,
                    ini,
                )
            }

            if e != &null {
                e->capped = self._calls != c0
            }

            var head = if kw.is_empty() => Doc::text(name + ": ")
                       else => Doc::concat2(kw, Doc::text(" " + name + ": "))
            if init == &null {
                return Doc::concat2(head, tyd)
            }

            return Doc::concat4(head, tyd, Doc::text(" = "), ini)
        }

        var v = self.fx(init, true)
        self._fill_row(e, ROW_UNTYPED(), kw, Doc::text(name), Doc::nothing(), v)
        if e != &null {
            e->capped = self._calls != c0
        }

        var head = if kw.is_empty() => Doc::text(name)
                   else => Doc::concat2(kw, Doc::text(" " + name))
        return Doc::concat3(head, Doc::text(" = "), v)
    }

    /// Header as written, the parameter list under rules 4.1 / 6.2, body
    /// formatted.
    priv fn _fn(self, f: unsafe *FunctionDecl, st: u32, en: u32) -> Doc {
        var be = en
        if f->body_kind == FnBodyKind::Block && f->body_block != &null {
            be = f->body_block->range.start.raw()
        }

        if f->body_kind == FnBodyKind::Expr && f->body_expr != &null {
            be = f->body_expr->range.start.raw()
        }

        var hd = self._fn_head(f, st, be)

        if f->body_kind == FnBodyKind::Block && f->body_block != &null {
            return Doc::concat3(hd, Doc::text(" "), self._block(f->body_block))
        }

        if f->body_kind == FnBodyKind::Expr && f->body_expr != &null {
            return Doc::concat3(hd, Doc::text(" "), self.fx(f->body_expr, true))
        }

        return hd
    }

    priv fn _fn_head(self, f: unsafe *FunctionDecl, st: u32, be: u32) -> Doc {
        if f->is_operator
            || f->params.is_empty()
            || f->params_end.is_invalid()
            || self._comment_in(st, be)
            || self._macro_in(st, be) {
            return self._span(st, be)
        }

        var c = self._lb(f->params_end.start.raw())
        if self._kind_at(c) != TokenKind::OpRParen {
            return self._span(st, be)
        }

        var o = self._match_open(c)
        if o >= self.toks.size() || self.toks[o].start < st {
            return self._span(st, be)
        }

        var starts = cxx::std::vector<u32>()
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null || p->range.is_invalid() {
                return self._span(st, be)
            }

            starts.push_back(p->range.start.raw())
        }

        var lo = cxx::std::vector<u32>()
        var hi = cxx::std::vector<u32>()
        if !self._slots(o, c, starts, unsafe &lo, unsafe &hi) {
            return self._span(st, be)
        }

        // a parameter is its slot: an attribute before its range (`@inout x:`)
        // and a default after it (`= &null`) are the parameter's too
        var keys = cxx::std::vector<Doc>()
        var vals = cxx::std::vector<Doc>()
        var flat = cxx::std::vector<Doc>()
        for var i: usize = 0; i < starts.size(); ++i {
            var a   = lo[i]
            var b   = hi[i]
            var col = self._top_colon(a, b)
            var key = Doc::nothing()
            var val = Doc::nothing()
            if col < self.toks.size() {
                key = self._span(a, self.toks[col].end)
                val = self._span(self.toks[col].end, b)
            }

            if key.is_empty() || key.hard || val.is_empty() {
                key = Doc::nothing()
                val = self._span(a, b)
            }

            if val.is_empty() {
                return self._span(st, be)
            }

            keys.push_back(key)
            vals.push_back(val)
            if i > 0 {
                flat.push_back(Doc::text(", "))
            }

            if !key.is_empty() {
                flat.push_back(key)
                flat.push_back(Doc::text(" "))
            }

            flat.push_back(val)
        }

        // a written trailing comma is not an item: the list's form decides it (4.2)
        var flags = LIST_ALIGNED() | LIST_KEYS()
        if rules().param_block_fallback {
            flags |= LIST_FALLBACK()
        }

        var fd = Doc::concat3(Doc::text("("), Doc::concat(flat), Doc::text(")"))
        var lst = Doc::list("(", ")", keys, vals, fd, flags)
        var hd  = Doc::concat2(self._span(st, self.toks[o].start), lst)

        var tail = self._span(self.toks[c].end, be)
        if tail.is_empty() {
            return hd
        }

        return Doc::concat3(hd, Doc::text(" "), tail)
    }

    /// The items between the opener at token \p o and the closer at \p c,
    /// one slot each: [lo[i], hi[i]) runs from the separator before item i to
    /// the one after it. \p starts are the items' range starts, which may sit
    /// after an attribute; the separators are the commas between them. False
    /// when the commas are not where the items say.
    fn _slots(self,
              o:      usize,
              c:      usize,
              starts: cxx::std::vector<u32>,
              lo:     unsafe *cxx::std::vector<u32>,
              hi:     unsafe *cxx::std::vector<u32>) -> bool {
        var n = starts.size()
        if n == 0 {
            return false
        }

        lo->push_back(self.toks[o].end)
        for var i: usize = 1; i < n; ++i {
            if starts[i] <= starts[i - 1] || starts[i] > self.toks[c].start {
                return false
            }

            var k          = self._lb(starts[i])
            var depth: i32 = 0
            var found      = self.toks.size()
            while k > o + 1 {
                k -= 1
                var t = self.toks[k].kind
                if Formatter::_is_close(t) {
                    depth += 1
                }

                if Formatter::_is_open(t) {
                    depth -= 1
                    if depth < 0 {
                        return false
                    }
                }

                if t == TokenKind::OpComma && depth == 0 {
                    found = k
                    break
                }
            }

            if found >= self.toks.size() || self.toks[found].start < starts[i - 1] {
                return false
            }

            hi->push_back(self.toks[found].start)
            lo->push_back(self.toks[found].end)
        }

        // the last slot ends at the closer, or at a trailing comma before it
        var l = self._sig_before(self.toks[c].start)
        if self._kind_at(l) == TokenKind::OpComma && self.toks[l].start >= starts[n - 1] {
            hi->push_back(self.toks[l].start)
        } else {
            hi->push_back(self.toks[c].start)
        }

        return true
    }

    /// Expression \p e in its slot [a, b): laid out when the slot holds
    /// exactly \p e and pairs of parens around it, else the slot as written
    /// (an attribute `@move x`, a comment). \p ok is cleared for the latter.
    fn _slot_expr(self, e: unsafe *Expr, a: u32, b: u32, ok: unsafe *bool) -> Doc {
        var f = self._sig_after(a)
        var l = self._sig_before(b)
        *ok = false
        if e == &null || f >= self.toks.size() || l >= self.toks.size() || self.toks[f].start >= b {
            return self._span(a, b)
        }

        if self._comment_in(a, b) || self._macro_in(a, b) {
            return self._span(a, b)
        }

        var es     = self._es(e)
        var ee     = self._ee(e)
        var k      = f
        var n: u32 = 0
        while self._kind_at(k) == TokenKind::OpLParen && self.toks[k].start < es {
            n += 1
            k = self._sig_after(self.toks[k].end)
        }

        if k >= self.toks.size() || self._prefix_start(self.toks[k].start) != es {
            return self._span(a, b)
        }

        var m       = self._sig_after(ee)
        var cl: u32 = 0
        while cl < n && self._kind_at(m) == TokenKind::OpRParen && self.toks[m].start < b {
            cl += 1
            m = self._sig_after(self.toks[m].end)
        }

        if cl != n || m < self.toks.size() && self.toks[m].start < b {
            return self._span(a, b)
        }

        *ok = true
        return self._wrap(e, self._expr(e), n, PCtx{})
    }

    /// Type \p t as written. Its range can run past its last token (to the
    /// start of whatever follows: a `)` closing the expression around it, the
    /// next line, an initializer), so it ends at the last token before an
    /// unbalanced closer, or a newline, `=` or `;` outside brackets.
    fn _type_doc(self, t: unsafe *Type) -> Doc {
        return self._v(t->range.start.raw(), self._type_end(t))
    }

    /// Where type \p t's text ends (see _type_doc).
    fn _type_end(self, t: unsafe *Type) -> u32 {
        var a          = t->range.start.raw()
        var b          = t->range.end.raw()
        var depth: i32 = 0
        var last       = a
        for var i = self._lb(a); i < self.toks.size(); ++i {
            var x = self.toks[i]
            if x.start >= b {
                break
            }

            if x.kind == TokenKind::TkNewLine && depth == 0 {
                break
            }

            if Formatter::trivia(x.kind) {
                continue
            }

            // a type holds no `=` or `;` outside brackets: an initializer or
            // the statement's end follows it
            if depth == 0 && (x.kind == TokenKind::OpEqual || x.kind == TokenKind::OpSemicolon) {
                break
            }

            if Formatter::_is_close(x.kind) {
                if depth == 0 {
                    break
                }

                depth -= 1
            }

            if Formatter::_is_open(x.kind) {
                depth += 1
            }

            last = x.end
        }

        return last
    }

    /// The first `:` in [a, b) outside brackets, or toks.size().
    priv fn _top_colon(self, a: u32, b: u32) -> usize {
        var depth: i32 = 0
        for var i = self._lb(a); i < self.toks.size(); ++i {
            var t = self.toks[i]
            if t.start >= b {
                break
            }

            if Formatter::_is_open(t.kind) {
                depth += 1
            }

            if Formatter::_is_close(t.kind) {
                depth -= 1
            }

            if t.kind == TokenKind::OpColon && depth == 0 {
                return i
            }
        }

        return self.toks.size()
    }

    /// class/struct/union/interface/extend/enum/module/`pub { }`/ffi block.
    /// \p typebody: a body rule 7.5 may keep on one line.
    priv fn _aggregate(self,
                       st:       u32,
                       en:       u32,
                       els:      unsafe *cxx::std::vector<Elem>,
                       typebody: bool) -> Doc {
        var n          = self.toks.size()
        var o          = n
        var depth: i32 = 0
        for var i = self._lb(st); i < n; ++i {
            var t = self.toks[i]
            if t.start >= en {
                break
            }

            if t.kind == TokenKind::OpLParen || t.kind == TokenKind::OpLSquare {
                depth += 1
            }

            if t.kind == TokenKind::OpRParen || t.kind == TokenKind::OpRSquare {
                depth -= 1
            }

            if t.kind == TokenKind::OpLBrace && depth == 0 {
                o = i
                break
            }
        }

        var c = self._sig_before(en)
        if o >= n || self._kind_at(c) != TokenKind::OpRBrace || o >= c {
            return self._v(st, en) // forward declaration
        }

        var head = self._span(st, self.toks[o].start)
        var one = typebody
            && self._line(self.toks[o].start) == self._line(self.toks[c].start)
            && !self._comment_in(self.toks[o].end, self.toks[c].start)
        return self._braced(
            head,
            self.toks[o].end,
            self.toks[c].start,
            self._line(self.toks[o].start),
            els,
            one,
        )
    }

    priv fn _variant(self, v: unsafe *EnumVariantDecl, st: u32, en: u32, e: unsafe *Entry) -> Doc {
        var unsafe *d = v->discriminant
        if d != &null && v->payload.is_empty() && !self._comment_in(st, en) {
            var eq = self._sig_before(d->range.start.raw())
            if self._kind_at(eq) == TokenKind::OpEqual {
                var key = self._span(st, self.toks[eq].start)
                var val = self._v(d->range.start.raw(), d->range.end.raw())
                if !key.hard && !val.hard {
                    self._fill_row(
                        e,
                        ROW_ENUM(),
                        key,
                        Doc::nothing(),
                        Doc::nothing(),
                        Doc::concat2(val, Doc::text(e->sep)),
                    )

                    return Doc::concat4(
                        key,
                        Doc::text(" = "),
                        val,
                        Doc::text(e->sep),
                    )
                }
            }
        }

        return Doc::concat2(self._v(st, en), Doc::text(e->sep))
    }

    // ----------------------------------------------------------------------
    //  Expressions
    // ----------------------------------------------------------------------

    /// \p e with the parentheses the source had around it. Semantic parses
    /// fold parens away, so they come back from the tokens: a pair inside the
    /// node's own range, and, at operand positions (\p ext), pairs glued
    /// around it.
    fn fx(self, e: unsafe *Expr, ext: bool) -> Doc {
        return self.fxc(e, ext, PCtx{})
    }

    /// fx in a known operand context: under `--normalize-parens` (rule 9.5)
    /// the pairs the parse does not need are dropped here.
    fn fxc(self, e: unsafe *Expr, ext: bool, pc: PCtx) -> Doc {
        if e == &null {
            return Doc::nothing()
        }

        var n: u32 = 0
        if ext {
            n = self._ext_parens(self._es(e), self._ee(e))
        }

        return self._wrap(e, self._expr(e), n, pc)
    }

    /// \p d, the layout of \p e, inside its own pair of parens (if its
    /// range is one) and \p ext more around it: under `--normalize-parens`
    /// (rule 9.5) only as many as the parse needs.
    fn _wrap(self, e: unsafe *Expr, d0: Doc, ext: u32, pc: PCtx) -> Doc {
        var d = d0
        var n = ext
        if self._int_parens(e) {
            n += 1
        }

        if n > 0 && self.set.normalize_parens && self._paren_candidate(e, pc) && !d.hard {
            n = if self._parens_needed(e, pc) || self._angle_hazard(e, ext) => 1 else => 0
        }

        for var i: u32 = 0; i < n; ++i {
            d = Doc::concat3(Doc::text("("), d, Doc::text(")"))
        }

        return d
    }

    /// Rule 9.5 candidates: an operator expression's parens, or a primary's
    /// as a prefix operand. Never an `if` / `try` expression, a tuple, a
    /// closure, a cast or a condition (kind 4).
    priv fn _paren_candidate(self, e: unsafe *Expr, pc: PCtx) -> bool {
        if pc.kind == 4 {
            return false
        }

        if isa<BinaryOperatorExpr>(e)
            || isa<AssignOperatorExpr>(e)
            || isa<UnaryOperatorExpr>(e)
            || isa<RangeExpr>(e) {
            return true
        }

        if pc.kind == 2 && rules().parens_unary_operand {
            return isa<ChainExpr>(e) || isa<CallExpr>(e) || isa<SubscriptExpr>(e)
        }

        return false
    }

    priv fn _prec_of(self, e: unsafe *Expr) -> i32 {
        if isa<BinaryOperatorExpr>(e) {
            return infix_prec(cast<BinaryOperatorExpr>(e)->op_token.kind)
        }

        if isa<AssignOperatorExpr>(e) {
            return 1
        }

        if isa<RangeExpr>(e) {
            return 3
        }

        return 16 // unary: tighter than every binary operator
    }

    priv fn _parens_needed(self, e: unsafe *Expr, pc: PCtx) -> bool {
        var p = self._prec_of(e)
        var prefix = isa<UnaryOperatorExpr>(e) && !cast<UnaryOperatorExpr>(e)->is_postfix()

        if pc.kind == 0 {
            return false
        }

        if pc.kind == 1 {
            if p == 0 || pc.prec == 0 {
                return true
            }

            if p > pc.prec {
                return false
            }

            if p < pc.prec {
                return true
            }

            // equal precedence: only the side associativity already groups
            if p == 3 { // ranges do not chain
                return true
            }

            if prec_right_assoc(p) {
                return !pc.right
            }

            return pc.right
        }

        if pc.kind == 2 {
            // a prefix operand: operators need the pair; so does a nested
            // prefix operator, whose tokens could glue (`- -x`, `& &x`)
            if p <= 15 || prefix {
                return true
            }

            return false
        }

        if pc.kind == 3 {
            // a postfix operand: `(*p)++` is not `*p++`
            return p <= 15 || prefix
        }

        return true
    }

    /// The pair around \p e (its own, or the outermost of \p ext glued ones)
    /// is what keeps a `<` and a `>` apart. The parser reads `name < ...`
    /// after an unknown name or a member step as tentative generic
    /// arguments, and commits when a `>` closes them before `(`, `.`, `,`,
    /// a line break and the like: `(xs[k].imp < 0) || f > (g)` without the
    /// pair is the call `imp<0 || f>(g)`. Precedence says the pair is
    /// redundant; the parse disagrees. So the pair stays when a depth-0 `<`
    /// inside it has a `>` after it in the statement, or a depth-0 `>` inside
    /// it has a `<` before it. Conservative: every real hazard is one of
    /// these, not every one of these is a hazard.
    priv fn _angle_hazard(self, e: unsafe *Expr, ext: u32) -> bool {
        var es = self._es(e)
        var ee = self._ee(e)
        var n  = self.toks.size()

        // what sits at the pair's depth 0
        var base:  i32 = if self._int_parens(e) => 1 else => 0
        var lt         = false
        var gt         = false
        var depth: i32 = 0
        for var i = self._lb(es); i < n && self.toks[i].start < ee; ++i {
            var k = self.toks[i].kind
            if Formatter::_is_open(k) {
                depth += 1
                continue
            }

            if Formatter::_is_close(k) {
                depth -= 1
                continue
            }

            if depth != base {
                continue
            }

            if k == TokenKind::OpLess {
                lt = true
            }

            if Formatter::_closes_angle(k) {
                gt = true
            }
        }

        if !lt && !gt {
            return false
        }

        // the outermost pair's own tokens
        var a = es
        var b = ee
        for var x: u32 = 0; x < ext; ++x {
            var o = self._sig_before(a)
            var c = self._sig_after(b)
            if o >= n || c >= n {
                return true
            }

            a = self.toks[o].start
            b = self.toks[c].end
        }

        if lt {
            // forward to the end of the statement or the enclosing bracket
            depth = 0
            for var i = self._lb(b); i < n; ++i {
                var k = self.toks[i].kind
                if depth == 0 && (k == TokenKind::OpSemicolon || k == TokenKind::OpLBrace) {
                    break
                }

                if Formatter::_is_open(k) {
                    depth += 1
                }

                if Formatter::_is_close(k) {
                    depth -= 1
                }

                if depth < 0 {
                    break
                }

                if Formatter::_closes_angle(k) {
                    return true
                }
            }
        }

        if gt {
            // back to the start of the statement or the enclosing bracket
            depth = 0
            var i = self._lb(a)
            while i > 0 {
                i -= 1
                var k = self.toks[i].kind
                if depth == 0 && (k == TokenKind::OpSemicolon || k == TokenKind::OpRBrace) {
                    break
                }

                if Formatter::_is_close(k) {
                    depth += 1
                }

                if Formatter::_is_open(k) {
                    depth -= 1
                }

                if depth < 0 {
                    break
                }

                if k == TokenKind::OpLess {
                    return true
                }
            }
        }

        return false
    }

    /// A token the generic-argument parser can close a `<` with.
    priv static fn _closes_angle(k: TokenKind) -> bool {
        return k == TokenKind::OpGreater
            || k == TokenKind::OpGreaterGreater
            || k == TokenKind::OpGreaterEqual
            || k == TokenKind::OpGreaterGreaterEqual
    }

    priv fn _wrapped(self, e: unsafe *Expr) -> bool {
        return self._int_parens(e) || self._ext_parens(self._es(e), self._ee(e)) > 0
    }

    fn _ext_parens(self, a: u32, b: u32) -> u32 {
        var n: u32 = 0
        var i      = self._sig_before(a)
        var j      = self._sig_after(b)
        while self._kind_at(i) == TokenKind::OpLParen
            && self._kind_at(j) == TokenKind::OpRParen
            && self._pair(i, j) {
            n += 1
            i = self._sig_before(self.toks[i].start)
            j = self._sig_after(self.toks[j].end)
        }

        return n
    }

    /// The `(` at token \p i is closed by the `)` at \p j, not earlier: in
    /// `(a) + (b)` the first `(` and the last `)` sit around the sum but
    /// are not one pair.
    priv fn _pair(self, i: usize, j: usize) -> bool {
        var depth: i32 = 0
        for var k = i; k <= j; ++k {
            var t = self.toks[k].kind
            if t == TokenKind::OpLParen {
                depth += 1
            }

            if t == TokenKind::OpRParen {
                depth -= 1
                if depth == 0 {
                    return k == j
                }
            }
        }

        return false
    }

    /// Where \p e's text starts. An operator expression's range starts at
    /// its first operand's, which is inside that operand's parens: in
    /// `(a) + b` the sum starts at `a`. Every `(` right before the range
    /// whose `)` closes inside it belongs to the expression.
    fn _es(self, e: unsafe *Expr) -> u32 {
        var a = self._prefix_start(e->range.start.raw())
        var b = e->range.end.raw()
        var p = self._sig_before(a)
        while self._kind_at(p) == TokenKind::OpLParen {
            var m = self._match_close(p)
            if m >= self.toks.size() || self.toks[m].start >= b {
                break
            }

            a = self.toks[p].start
            p = self._sig_before(a)
        }

        return a
    }

    /// Where \p e's text ends: the mirror of _es (`a + (b)` ends at `b`).
    fn _ee(self, e: unsafe *Expr) -> u32 {
        var a = self._es(e)
        var b = e->range.end.raw()
        // `"a " "b"`: one literal node, its range the first piece only
        if isa<StringLiteralExpr>(e) {
            var i = self._lb(e->range.start.raw())
            if i < self.toks.size() && self.toks[i].kind == TokenKind::LitString {
                var c = self._chain_end(i)
                if c > b {
                    b = c
                }
            }
        }

        var q = self._sig_after(b)
        while self._kind_at(q) == TokenKind::OpRParen {
            var m = self._match_open(q)
            if m >= self.toks.size() || self.toks[m].start < a {
                break
            }

            b = self.toks[q].end
            q = self._sig_after(b)
        }

        return b
    }

    /// The `)` matching the `(` at token \p i, or toks.size().
    priv fn _match_close(self, i: usize) -> usize {
        var depth: i32 = 0
        for var k = i; k < self.toks.size(); ++k {
            var t = self.toks[k].kind
            if t == TokenKind::OpLParen {
                depth += 1
            }

            if t == TokenKind::OpRParen {
                depth -= 1
                if depth == 0 {
                    return k
                }
            }
        }

        return self.toks.size()
    }

    /// A string or char literal at \p a with its prefix glued in front
    /// (`f"..."`, `r"..."`, `rf"..."`). The lexer folds the prefix into the
    /// literal's immediate and makes no token of it, and the node's range
    /// starts at the quote, so the prefix is found in the bytes.
    fn _prefix_start(self, a: u32) -> u32 {
        var i = self._lb(a)
        if i >= self.toks.size() || self.toks[i].start != a {
            return a
        }

        var k = self.toks[i].kind
        if k != TokenKind::LitString && k != TokenKind::LitChar {
            return a
        }

        var off       = (a - self.base) as usize
        var n:  usize = 0
        while off > n && n < 3 && Formatter::_alpha(self.src[off - n - 1]) {
            n += 1
        }

        if n == 0 {
            return a
        }

        // a prefix stands alone: the byte before it is not part of a word
        if off > n
            && (Formatter::_alpha(self.src[off - n - 1])
                || self.src[off - n - 1] == ('_' as u8)
                || self.src[off - n - 1] >= ('0' as u8) && self.src[off - n - 1] <= ('9' as u8)) {
            return a
        }

        return a - (n as u32)
    }

    priv static fn _alpha(c: u8) -> bool {
        return c >= ('a' as u8) && c <= ('z' as u8) || c >= ('A' as u8) && c <= ('Z' as u8)
    }

    /// The end of the last code token in [a, b), or \p b. A node's range can
    /// run past its last token over trivia: a type with no `;` after it
    /// reaches across the line break into the next line's doc comment.
    fn _code_end(self, a: u32, b: u32) -> u32 {
        var l = self._sig_before(b)
        if l >= self.toks.size() || self.toks[l].start < a {
            return b
        }

        if self.toks[l].kind == TokenKind::LitString {
            return self._chain_end(l)
        }

        return self.toks[l].end
    }

    /// The end of the string literal token \p i with the pieces chained to
    /// it (`"a " "b"`). The lexer folds a chain into the first piece's
    /// immediate and makes no token of the rest: they are bytes between
    /// tokens, so they are found that way.
    fn _chain_end(self, i: usize) -> u32 {
        var b = self.toks[i].end
        var k = i
        while k + 1 < self.toks.size() {
            var gs = self.toks[k].end
            // the next literal's prefix (`f` of `"a" "b"\n f"c"`) sits in the
            // gap too but is that literal's; taking it split `f` from its
            // quote onto a line of its own
            var ge = self._prefix_start(self.toks[k + 1].start)
            if ge > gs && self._trimmed(gs, ge).size() > 0 {
                b = self._trim_back(gs, ge, true)
            }

            var kk = self.toks[k + 1].kind
            if kk != TokenKind::TkWhitespace && kk != TokenKind::TkNewLine {
                break
            }

            k += 1
        }

        return b
    }

    /// \p a moved back over each `(` before it whose `)` closes inside [a, b).
    fn _grow_start(self, a: u32, b: u32) -> u32 {
        var s = self._prefix_start(a)
        var p = self._sig_before(s)
        while self._kind_at(p) == TokenKind::OpLParen {
            var m = self._match_close(p)
            if m >= self.toks.size() || self.toks[m].start >= b {
                break
            }

            s = self.toks[p].start
            p = self._sig_before(s)
        }

        return s
    }

    /// \p b moved past each `)` after it whose `(` opened inside [a, b).
    fn _grow_end(self, a: u32, b: u32) -> u32 {
        var e = b
        var q = self._sig_after(e)
        while self._kind_at(q) == TokenKind::OpRParen {
            var m = self._match_open(q)
            if m >= self.toks.size() || self.toks[m].start < a {
                break
            }

            e = self.toks[q].end
            q = self._sig_after(e)
        }

        return e
    }

    /// The `(` matching the `)` at token \p j, or toks.size().
    priv fn _match_open(self, j: usize) -> usize {
        var depth: i32 = 0
        var k          = j + 1
        while k > 0 {
            k -= 1
            var t = self.toks[k].kind
            if t == TokenKind::OpRParen {
                depth += 1
            }

            if t == TokenKind::OpLParen {
                depth -= 1
                if depth == 0 {
                    return k
                }
            }
        }

        return self.toks.size()
    }

    /// The node's own range is one parenthesized whole: `(a + b)`.
    priv fn _int_parens(self, e: unsafe *Expr) -> bool {
        if isa<TupleLiteralExpr>(e) || isa<ParenExpr>(e) {
            return false
        }

        var f = self._sig_after(self._es(e))
        var l = self._sig_before(self._ee(e))
        if f >= l || l >= self.toks.size() {
            return false
        }

        if self.toks[f].kind != TokenKind::OpLParen || self.toks[l].kind != TokenKind::OpRParen {
            return false
        }

        var depth: i32 = 0
        for var i = f; i <= l; ++i {
            var k = self.toks[i].kind
            if k == TokenKind::OpLParen {
                depth += 1
            }

            if k == TokenKind::OpRParen {
                depth -= 1
                if depth == 0 && i < l {
                    return false
                }
            }
        }

        return true
    }

    /// \p e as written, minus a parenthesized range's own pair (fx adds it).
    priv fn _ev(self, e: unsafe *Expr) -> Doc {
        var a = self._es(e)
        var b = self._ee(e)
        if self._int_parens(e) {
            return self._span(
                self.toks[self._sig_after(a)].end,
                self.toks[self._sig_before(b)].start,
            )
        }

        return self._v(a, b)
    }

    priv fn _expr(self, e: unsafe *Expr) -> Doc {
        var a = self._es(e)
        var b = self._ee(e)

        if e->kind == ExprKind::RecoveryExpr || e->range.is_invalid() {
            return self._ev(e)
        }

        if self._comment_in(a, b) || self._macro_in(a, b) {
            return self._ev(e)
        }

        if isa<ChainExpr>(e) {
            return self._chain(cast<ChainExpr>(e))
        }

        if isa<CallExpr>(e) {
            return self._call(cast<CallExpr>(e))
        }

        if isa<BinaryOperatorExpr>(e) {
            return self._binary(cast<BinaryOperatorExpr>(e))
        }

        if isa<NamedArgExpr>(e) {
            var unsafe *na = cast<NamedArgExpr>(e)
            return Doc::concat2(
                Doc::text(self._tok(na->name) + ": "),
                self.fx(na->value, false),
            )
        }

        if isa<SubscriptExpr>(e) {
            var unsafe *s = cast<SubscriptExpr>(e)
            var        c  = self._sig_before(b)
            if s->base == &null || s->index == &null || self._kind_at(c) != TokenKind::OpRSquare {
                return self._ev(e)
            }

            var o = self._sig_after(self._ee(s->base))
            if self._kind_at(o) != TokenKind::OpLSquare || o >= c {
                return self._ev(e)
            }

            var ok = false
            var ix = self._slot_expr(
                s->index,
                self.toks[o].end,
                self.toks[c].start,
                unsafe &ok,
            )

            return Doc::concat4(
                self.fxc(s->base, true, PCtx { kind: 3, prec: 0, right: false }),
                Doc::text("["),
                ix,
                Doc::text("]"),
            )
        }

        if isa<ListLiteralExpr>(e) {
            var unsafe *l = cast<ListLiteralExpr>(e)
            var        xs = cxx::std::vector<unsafe *Expr>()
            for var i: usize = 0; i < l->elements.size(); ++i {
                xs.push_back(l->elements[i])
            }

            return self._seq(
                e,
                TokenKind::OpLSquare,
                TokenKind::OpRSquare,
                xs,
                LIST_GRID(),
            )
        }

        if isa<TupleLiteralExpr>(e) {
            var unsafe *t = cast<TupleLiteralExpr>(e)
            var        xs = cxx::std::vector<unsafe *Expr>()
            for var i: usize = 0; i < t->elements.size(); ++i {
                xs.push_back(t->elements[i])
            }

            // (no one-element tuples: `(x,)` is S054E, so no comma is ever kept flat)
            return self._seq(
                e,
                TokenKind::OpLParen,
                TokenKind::OpRParen,
                xs,
                LIST_GRID(),
            )
        }

        if isa<NamedInitializerExpr>(e) {
            var unsafe *ni = cast<NamedInitializerExpr>(e)
            if ni->is_dotted || ni->type_expr == &null || ni->fields.is_empty() {
                return self._ev(e)
            }

            var c = self._sig_before(b)
            var o = self._sig_after(self._ee(ni->type_expr))
            if self._kind_at(c) != TokenKind::OpRBrace
                || self._kind_at(o) != TokenKind::OpLBrace
                || o >= c {
                return self._ev(e)
            }

            var starts = cxx::std::vector<u32>()
            for var i: usize = 0; i < ni->fields.size(); ++i {
                starts.push_back(ni->fields.get(i)->name.range.start.raw())
            }

            var lo = cxx::std::vector<u32>()
            var hi = cxx::std::vector<u32>()
            if !self._slots(o, c, starts, unsafe &lo, unsafe &hi) {
                return self._ev(e)
            }

            var keys = cxx::std::vector<Doc>()
            var vals = cxx::std::vector<Doc>()
            var flat = cxx::std::vector<Doc>()
            flat.push_back(Doc::text("{ "))
            for var i: usize = 0; i < ni->fields.size(); ++i {
                var unsafe *f = ni->fields.get(i)
                // `name: value`, the value alone in the rest of the slot
                var nm  = self._sig_after(lo[i])
                var co  = self._sig_after(self.toks[nm].end)
                var ok  = false
                var val = Doc::nothing()
                if self.toks[nm].start == starts[i] && self._kind_at(co) == TokenKind::OpColon {
                    val = self._slot_expr(
                        f->value,
                        self.toks[co].end,
                        hi[i],
                        unsafe &ok,
                    )
                }

                if ok {
                    keys.push_back(Doc::text(self._tok(f->name) + ":"))
                    vals.push_back(val)
                } else {
                    keys.push_back(Doc::nothing())
                    vals.push_back(self._span(lo[i], hi[i]))
                }

                if i > 0 {
                    flat.push_back(Doc::text(", "))
                }

                if !keys[i].is_empty() {
                    flat.push_back(keys[i])
                    flat.push_back(Doc::text(" "))
                }

                flat.push_back(vals[i])
            }

            flat.push_back(Doc::text(" }"))
            return Doc::concat3(
                self.fxc(
                    ni->type_expr,
                    true,
                    PCtx { kind: 3, prec: 0, right: false },
                ),
                Doc::text(" "),
                Doc::list("{", "}", keys, vals, Doc::concat(flat), LIST_KEYS()),
            )
        }

        if isa<UnaryOperatorExpr>(e) {
            var unsafe *u  = cast<UnaryOperatorExpr>(e)
            var        _op = self._tok(u->op_token)
            if u->is_postfix() {
                return Doc::concat2(
                    self.fxc(
                        u->operand,
                        true,
                        PCtx { kind: 3, prec: 0, right: false },
                    ),
                    Doc::text(_op),
                )
            }

            // word operators (`not`) need their space back
            var word = _op.size() > 0
                && (_op[0] >= ('a' as u8) && _op[0] <= ('z' as u8)
                    || _op[0] >= ('A' as u8) && _op[0] <= ('Z' as u8))
            if word {
                _op += " "
            }

            return Doc::concat2(
                Doc::text(_op),
                self.fxc(
                    u->operand,
                    true,
                    PCtx { kind: 2, prec: 0, right: false },
                ),
            )
        }

        if isa<AssignOperatorExpr>(e) {
            var unsafe *x = cast<AssignOperatorExpr>(e)
            return Doc::concat3(
                self.fxc(x->lhs, true, PCtx { kind: 1, prec: 1, right: false }),
                Doc::text(" " + self._tok(x->op_token) + " "),
                self.fxc(x->rhs, true, PCtx { kind: 1, prec: 1, right: true }),
            )
        }

        if isa<RangeExpr>(e) {
            var unsafe *r  = cast<RangeExpr>(e)
            var        _op = if r->is_inclusive => "..=" else => ".."
            return Doc::concat3(
                self.fxc(
                    r->begin,
                    true,
                    PCtx { kind: 1, prec: 3, right: false },
                ),
                Doc::text(_op),
                self.fxc(r->end, true, PCtx { kind: 1, prec: 3, right: true }),
            )
        }

        if isa<TypeCastExpr>(e) {
            var unsafe *c = cast<TypeCastExpr>(e)
            if c->mode != CastMode::Default || c->target == &null {
                return self._ev(e)
            }

            return Doc::concat3(
                self.fxc(
                    c->operand,
                    true,
                    PCtx { kind: 4, prec: 0, right: false },
                ),
                Doc::text(" as "),
                self._type_doc(c->target),
            )
        }

        if isa<IfExpr>(e) && rules().if_expr_layout {
            return self._if_expr(cast<IfExpr>(e))
        }

        if isa<TryCatchExpr>(e) && rules().try_expr_layout {
            return self._try_expr(cast<TryCatchExpr>(e))
        }

        if isa<MatchExpr>(e) && rules().match_expr_break {
            return self._match_expr(cast<MatchExpr>(e))
        }

        if isa<AwaitExpr>(e) {
            return Doc::concat2(
                Doc::text("await "),
                self.fxc(
                    cast<AwaitExpr>(e)->operand,
                    true,
                    PCtx { kind: 4, prec: 0, right: false },
                ),
            )
        }

        if isa<SpawnExpr>(e) {
            return Doc::concat2(
                Doc::text("spawn "),
                self.fxc(
                    cast<SpawnExpr>(e)->operand,
                    true,
                    PCtx { kind: 4, prec: 0, right: false },
                ),
            )
        }

        if isa<ThreadExpr>(e) {
            return Doc::concat2(
                Doc::text("thread "),
                self.fxc(
                    cast<ThreadExpr>(e)->operand,
                    true,
                    PCtx { kind: 4, prec: 0, right: false },
                ),
            )
        }

        if isa<EvalExpr>(e) {
            return Doc::concat2(
                Doc::text("eval "),
                self.fxc(
                    cast<EvalExpr>(e)->operand,
                    true,
                    PCtx { kind: 4, prec: 0, right: false },
                ),
            )
        }

        if isa<UnsafeExpr>(e) {
            return Doc::concat2(
                Doc::text("unsafe "),
                self.fxc(
                    cast<UnsafeExpr>(e)->operand,
                    true,
                    PCtx { kind: 4, prec: 0, right: false },
                ),
            )
        }

        if isa<PackExpansionExpr>(e) {
            return Doc::concat2(
                self.fxc(
                    cast<PackExpansionExpr>(e)->operand,
                    true,
                    PCtx { kind: 4, prec: 0, right: false },
                ),
                Doc::text("..."),
            )
        }

        if isa<ParenExpr>(e) {
            return Doc::concat3(
                Doc::text("("),
                self.fx(cast<ParenExpr>(e)->inner, false),
                Doc::text(")"),
            )
        }

        if isa<ConstraintExpr>(e) {
            var unsafe *c = cast<ConstraintExpr>(e)
            if c->rhs == &null {
                return self._ev(e)
            }

            return Doc::concat3(
                self.fxc(c->lhs, true, PCtx { kind: 4, prec: 0, right: false }),
                Doc::text(" " + self._tok(c->op_token) + " "),
                self._type_doc(c->rhs),
            )
        }

        if isa<ClosureExpr>(e) {
            return self._closure(cast<ClosureExpr>(e))
        }

        // literals, names, initializers with no head, sizeof/typeof,
        // unwrap!/defined!, attributes, if/try/match expressions, the rest
        return self._ev(e)
    }

    /// Rule 9.7: a closure with a block body is its head as written, then
    /// the block. A body written on one line with one statement stays on one
    /// line while it fits (`_op_form(at, k, fn () { s->spell(at, p) }, t)`
    /// would be three lines per argument under 8.1); any other body is laid
    /// out by 8.1. Either way the body gets 13.1 and 9.5 like any block,
    /// which a copied closure did not.
    priv fn _closure(self, c: unsafe *ClosureExpr) -> Doc {
        var unsafe *b = c->body_block
        if b == &null {
            return self._ev(c)
        }

        var a = self._es(c)
        var z = b->range.end.raw()
        var o = self._sig_after(b->range.start.raw())
        var k = self._sig_before(z)
        if self._kind_at(o) != TokenKind::OpLBrace || self._kind_at(k) != TokenKind::OpRBrace {
            return self._ev(c)
        }

        var head = self._span(a, b->range.start.raw())
        // a closure sits inside a statement: the block flags belong to that
        // statement's own blocks, so this one leaves them as it found them
        var ungroup = self._ungroup_next
        var broken  = self._blk_broken
        self._ungroup_next = false

        var lo   = self.toks[o].end
        var hi   = self.toks[k].start
        var body = Doc::nothing()
        if self._line(a) == self._line(z - 1)
            && b->body.size() == 1
            && !self._comment_in(lo, hi)
            && !self._is_block_stmt(b->body[0])
            && !self._macro_in(lo, hi) {
            var unsafe *s0 = b->body[0]
            var        sa  = s0->range.start.raw()
            var        se  = s0->range.end.raw()
            var        sd  = self._stmt(s0, sa, self._core_end(sa, se), &null)
            body = Doc::group(
                Doc::concat3(
                    Doc::text("{"),
                    Doc::indent(Doc::concat2(Doc::line(), sd)),
                    Doc::concat2(Doc::line(), Doc::text("}")),
                ),
            )
        } else {
            body = self._block(b)
        }

        self._ungroup_next = ungroup
        self._blk_broken   = broken
        if head.is_empty() {
            return body
        }

        return Doc::concat3(head, Doc::text(" "), body)
    }

    /// Rule 8.3: `if c => a else if d => b else => z` on one line while it
    /// fits; otherwise broken before each `else`, one level in. Only the
    /// `=>` form, and only when the tokens between the parts are exactly the
    /// keywords; anything else is copied. The arms keep every paren they
    /// were written with (S077E / S078W ask for them).
    priv fn _if_expr(self, x: unsafe *IfExpr) -> Doc {
        if x->condition == &null || x->then_expr == &null || x->else_expr == &null {
            return self._ev(x)
        }

        var keep = PCtx { kind: 4, prec: 0, right: false }

        var t = self._sig_after(self._es(x))
        if self._kind_at(t) != TokenKind::KwIf {
            return self._ev(x)
        }

        if !self._next_is(self.toks[t].end, x->condition) {
            return self._ev(x)
        }

        var parts = cxx::std::vector<Doc>()
        if !self._arrow_then(x->condition, x->then_expr) {
            return self._ev(x)
        }

        parts.push_back(Doc::text("if "))
        parts.push_back(self.fxc(x->condition, true, keep))
        parts.push_back(Doc::text(" => "))
        parts.push_back(self.fxc(x->then_expr, true, keep))

        var unsafe *prev = x->then_expr
        var        tail  = cxx::std::vector<Doc>()
        for var i: usize = 0; i < x->else_ifs.size(); ++i {
            var unsafe *ei = x->else_ifs.get(i)
            if ei->condition == &null || ei->body == &null {
                return self._ev(x)
            }

            var el = self._after_expr(prev)
            if self._kind_at(el) != TokenKind::KwElse {
                return self._ev(x)
            }

            var kif = self._sig_after(self.toks[el].end)
            if self._kind_at(kif) != TokenKind::KwIf
                || !self._next_is(self.toks[kif].end, ei->condition) {
                return self._ev(x)
            }

            if !self._arrow_then(ei->condition, ei->body) {
                return self._ev(x)
            }

            tail.push_back(Doc::line())
            tail.push_back(Doc::text("else if "))
            tail.push_back(self.fxc(ei->condition, true, keep))
            tail.push_back(Doc::text(" => "))
            tail.push_back(self.fxc(ei->body, true, keep))
            prev = ei->body
        }

        var el = self._after_expr(prev)
        if self._kind_at(el) != TokenKind::KwElse {
            return self._ev(x)
        }

        var ar = self._sig_after(self.toks[el].end)
        if self._kind_at(ar) != TokenKind::OpFatArrow
            || !self._next_is(self.toks[ar].end, x->else_expr) {
            return self._ev(x)
        }

        tail.push_back(Doc::line())
        tail.push_back(Doc::text("else => "))
        tail.push_back(self.fxc(x->else_expr, true, keep))
        if !rules().if_expr_align {
            parts.push_back(Doc::indent(Doc::concat(tail)))
            return Doc::group(Doc::concat(parts))
        }

        // every clause at the `if`'s column, the first `if`
        // right-aligned under the `else if`s so the conditions line up
        // (`     if` / `else if` / `else`); the last `else` has no condition
        // and starts the column
        parts.push_back(Doc::concat(tail))
        var body = Doc::concat(parts)
        if x->else_ifs.size() > 0 {
            body = Doc::concat2(
                Doc::if_break(Doc::text("     "), Doc::nothing()),
                body,
            )
        }

        return Doc::group(Doc::align(body))
    }

    /// Rule 8.3: `try x catch e: T => v catch => w` on one
    /// line while it fits; otherwise each `catch` starts a line in the
    /// `try`'s column, the arms' `=>` aligned (a section 11 table). Only
    /// when every arm is `catch ... => value` with a one-line head and a
    /// value that is not itself broken; anything else is copied.
    priv fn _try_expr(self, x: unsafe *TryCatchExpr) -> Doc {
        if x->try_expr == &null || x->catch_arms.size() == 0 {
            return self._ev(x)
        }

        var keep = PCtx { kind: 4, prec: 0, right: false }

        var t = self._sig_after(self._es(x))
        if self._kind_at(t) != TokenKind::KwTry || !self._next_is(self.toks[t].end, x->try_expr) {
            return self._ev(x)
        }

        var opd = self.fxc(x->try_expr, true, keep)
        if opd.hard {
            return self._ev(x)
        }

        var flat  = cxx::std::vector<Doc>()
        var cells = cxx::std::vector<Doc>()
        flat.push_back(Doc::text("try "))
        flat.push_back(opd)
        var unsafe *prev = x->try_expr
        for var i: usize = 0; i < x->catch_arms.size(); ++i {
            var unsafe *arm = x->catch_arms.get(i)
            if arm->body == &null {
                return self._ev(x)
            }

            var c = self._after_expr(prev)
            if self._kind_at(c) != TokenKind::KwCatch {
                return self._ev(x)
            }

            var bs = self._es(arm->body)
            var ar = self._sig_before(bs)
            var np = self._ext_parens(bs, self._ee(arm->body))
            for var k: u32 = 0; k < np; ++k {
                ar = self._sig_before(self.toks[ar].start)
            }

            if self._kind_at(ar) != TokenKind::OpFatArrow || ar <= c {
                return self._ev(x)
            }

            if self._line(self.toks[c].start) != self._line(self.toks[ar].start) {
                return self._ev(x)
            }

            var head = self._span(self.toks[c].start, self.toks[ar].start)
            var val  = self.fxc(arm->body, true, keep)
            if val.hard {
                return self._ev(x)
            }

            flat.push_back(Doc::text(" "))
            flat.push_back(head)
            flat.push_back(Doc::text(" => "))
            flat.push_back(val)
            cells.push_back(head)
            cells.push_back(Doc::concat2(Doc::text("=> "), val))
            prev = arm->body
        }

        var seps = cxx::std::vector<string>()
        seps.push_back("")
        seps.push_back(" ")
        var broken = Doc::align(
            Doc::concat5(
                Doc::text("try "),
                opd,
                Doc::hardline(),
                Doc::table(cells, 2, seps),
                Doc::nothing(),
            ),
        )

        return Doc::choice(Doc::concat(flat), broken)
    }

    /// Rule 8.4: a `match` expression with more than
    /// match_expr_max_flat() cases is broken, one `case` per line one level
    /// in; with fewer it is copied as written. Only when the arms are
    /// `case ... => value` with nothing but line breaks between them.
    priv fn _match_expr(self, x: unsafe *MatchExpr) -> Doc {
        if x->scrutinee == &null || x->cases.size() <= match_expr_max_flat() {
            return self._ev(x)
        }

        var a = self._es(x)
        var b = self._ee(x)
        var m = self._sig_after(a)
        if self._kind_at(m) != TokenKind::KwMatch
            || !self._next_is(self.toks[m].end, x->scrutinee) {
            return self._ev(x)
        }

        var o = self._after_expr(x->scrutinee)
        var c = self._sig_before(b)
        if self._kind_at(o) != TokenKind::OpLBrace
            || self._kind_at(c) != TokenKind::OpRBrace
            || o >= c {
            return self._ev(x)
        }

        var rows = cxx::std::vector<Doc>()
        var cur  = self.toks[o].end
        for var i: usize = 0; i < x->cases.size(); ++i {
            var unsafe *mc = x->cases.get(i)
            if mc->range.is_invalid() || mc->expression == &null {
                return self._ev(x)
            }

            var st = mc->range.start.raw()
            // nothing but line breaks before the arm
            if self._has_sig(cur, st) {
                return self._ev(x)
            }

            var d = self._case_value(mc, st)
            if d.is_empty() {
                return self._ev(x)
            }

            rows.push_back(Doc::hardline())
            rows.push_back(d)
            // past the value and the parens glued around it
            var q = self._after_expr(mc->expression)
            if q >= self.toks.size() {
                return self._ev(x)
            }

            cur = self.toks[q].start
        }

        if self._sig_after(cur) != c {
            return self._ev(x)
        }

        return Doc::concat5(
            Doc::text("match "),
            self.fxc(
                x->scrutinee,
                true,
                PCtx { kind: 4, prec: 0, right: false },
            ),
            Doc::text(" {"),
            Doc::indent(Doc::concat(rows)),
            Doc::concat2(Doc::hardline(), Doc::text("}")),
        )
    }

    /// The first code token after \p e with the parens glued around it.
    priv fn _after_expr(self, e: unsafe *Expr) -> usize {
        var q = self._sig_after(self._ee(e))
        var n = self._ext_parens(self._es(e), self._ee(e))
        for var i: u32 = 0; i < n; ++i {
            q = self._sig_after(self.toks[q].end)
        }

        return q
    }

    /// \p e (with any parens glued around it) is the next thing after \p a.
    priv fn _next_is(self, a: u32, e: unsafe *Expr) -> bool {
        var n = self._ext_parens(self._es(e), self._ee(e))
        var f = self._sig_after(a)
        for var i: u32 = 0; i < n; ++i {
            if self._kind_at(f) != TokenKind::OpLParen {
                return false
            }

            f = self._sig_after(self.toks[f].end)
        }

        return f < self.toks.size() && self._prefix_start(self.toks[f].start) == self._es(e)
    }

    /// `cond => value`: the `=>` right after \p c, then \p v.
    priv fn _arrow_then(self, c: unsafe *Expr, v: unsafe *Expr) -> bool {
        var ar = self._after_expr(c)
        if self._kind_at(ar) != TokenKind::OpFatArrow {
            return false
        }

        return self._next_is(self.toks[ar].end, v)
    }

    /// A rule 4.1 list of positional items, the elements of \p e between its
    /// \p open and \p close tokens: block form when broken (grid where
    /// \p flags allows), trailing comma by form.
    priv fn _seq(self,
                 e:     unsafe *Expr,
                 open:  TokenKind,
                 close: TokenKind,
                 items: cxx::std::vector<unsafe *Expr>,
                 flags: u32) -> Doc {
        var o = self._sig_after(self._es(e))
        var c = self._sig_before(self._ee(e))
        if self._kind_at(o) != open || self._kind_at(c) != close || o >= c {
            return self._ev(e)
        }

        var os = self.tok_text(o)
        var cs = self.tok_text(c)
        if items.empty() {
            return Doc::text(os + cs)
        }

        var starts = cxx::std::vector<u32>()
        for var i: usize = 0; i < items.size(); ++i {
            if items[i] == &null {
                return self._ev(e)
            }

            starts.push_back(self._es(items[i]))
        }

        var lo = cxx::std::vector<u32>()
        var hi = cxx::std::vector<u32>()
        if !self._slots(o, c, starts, unsafe &lo, unsafe &hi) {
            return self._ev(e)
        }

        var keys = cxx::std::vector<Doc>()
        var vals = cxx::std::vector<Doc>()
        var flat = cxx::std::vector<Doc>()
        flat.push_back(Doc::text(os))
        for var i: usize = 0; i < items.size(); ++i {
            var ok = false
            keys.push_back(Doc::nothing())
            vals.push_back(self._slot_expr(items[i], lo[i], hi[i], unsafe &ok))
            if i > 0 {
                flat.push_back(Doc::text(", "))
            }

            flat.push_back(vals[i])
        }

        flat.push_back(Doc::text(cs))
        return Doc::list(os, cs, keys, vals, Doc::concat(flat), flags)
    }

    priv fn _chain(self, c: unsafe *ChainExpr) -> Doc {
        for var i: usize = 0; i < c->steps.size(); ++i {
            if !c->steps.get(i)->generic_args.is_empty() {
                return self._ev(c)
            }
        }

        var parts = cxx::std::vector<Doc>()
        if c->base != &null {
            parts.push_back(
                self.fxc(c->base, true, PCtx { kind: 3, prec: 0, right: false }),
            )
        }

        for var i: usize = 0; i < c->steps.size(); ++i {
            var unsafe *s = c->steps.get(i)
            if s->is_operator() {
                return self._ev(c)
            }

            match s->access_kind {
                case ChainExpr::AccessKind::Dot {
                    parts.push_back(Doc::text("."))
                } case ChainExpr::AccessKind::Arrow {
                    parts.push_back(Doc::text("->"))
                } case ChainExpr::AccessKind::ColonColon {
                    parts.push_back(Doc::text("::"))
                } case ChainExpr::AccessKind::QuestionDot {
                    parts.push_back(Doc::text("?."))
                } case ChainExpr::AccessKind::QuestionArrow {
                    parts.push_back(Doc::text("?->"))
                }
            }

            if s->is_tuple_index() {
                parts.push_back(Doc::text(f"{s->index}"))
            } else if s->name != &null {
                parts.push_back(Doc::text(self._tok(s->name->name)))
            } else {
                return self._ev(c)
            }
        }

        return Doc::concat(parts)
    }

    /// Rule 4.1 call: flat only when it ends by the call width (80, or
    /// `--call-width=N`, 2.8);
    /// broken in the block form, named arguments' values in one column (11.3).
    priv fn _call(self, c: unsafe *CallExpr) -> Doc {
        if c->callee == &null {
            return self._ev(c)
        }

        var cl = self._sig_before(self._ee(c))
        if self._kind_at(cl) != TokenKind::OpRParen {
            return self._ev(c)
        }

        var lp = self._match_open(cl)
        if lp >= self.toks.size() || self.toks[lp].start < self._ee(c->callee) {
            return self._ev(c)
        }

        self._calls += 1

        var keys = cxx::std::vector<Doc>()
        var vals = cxx::std::vector<Doc>()
        var flat = cxx::std::vector<Doc>()
        flat.push_back(Doc::text("("))
        if !c->args.is_empty() {
            var starts = cxx::std::vector<u32>()
            for var i: usize = 0; i < c->args.size(); ++i {
                if c->args[i] == &null {
                    return self._ev(c)
                }

                starts.push_back(self._es(c->args[i]))
            }

            var lo = cxx::std::vector<u32>()
            var hi = cxx::std::vector<u32>()
            if !self._slots(lp, cl, starts, unsafe &lo, unsafe &hi) {
                return self._ev(c)
            }

            for var i: usize = 0; i < c->args.size(); ++i {
                var unsafe *a = c->args[i]
                if i > 0 {
                    flat.push_back(Doc::text(", "))
                }

                var ok = false
                if isa<NamedArgExpr>(a) {
                    // `name: value`, the value alone in the rest of the slot
                    var unsafe *na = cast<NamedArgExpr>(a)
                    var        nm  = self._sig_after(lo[i])
                    var        co  = self._sig_after(self.toks[nm].end)
                    var        val = Doc::nothing()
                    if self.toks[nm].start == na->name.range.start.raw()
                        && self._kind_at(co) == TokenKind::OpColon {
                        val = self._slot_expr(
                            na->value,
                            self.toks[co].end,
                            hi[i],
                            unsafe &ok,
                        )
                    }

                    if ok {
                        keys.push_back(Doc::text(self._tok(na->name) + ":"))
                        vals.push_back(val)
                        flat.push_back(keys[i])
                        flat.push_back(Doc::text(" "))
                        flat.push_back(val)
                        continue
                    }

                    keys.push_back(Doc::nothing())
                    vals.push_back(self._span(lo[i], hi[i]))
                    flat.push_back(vals[i])
                    continue
                }

                keys.push_back(Doc::nothing())
                vals.push_back(self._slot_expr(a, lo[i], hi[i], unsafe &ok))
                flat.push_back(vals[i])
            }
        }

        flat.push_back(Doc::text(")"))

        // the callee, then whatever sits between it and the `(` (generic
        // arguments the chain did not take), as written
        var callee = self.fxc(
            c->callee,
            true,
            PCtx { kind: 3, prec: 0, right: false },
        )

        var mid = self._span(self._ee(c->callee), self.toks[lp].start)
        if mid.hard {
            return self._ev(c)
        }

        if c->args.is_empty() {
            return Doc::concat3(callee, mid, Doc::text("()"))
        }

        var lst = Doc::list(
            "(",
            ")",
            keys,
            vals,
            Doc::concat(flat),
            LIST_KEYS(),
        )

        lst.num = self.set.call_width
        return Doc::concat3(callee, mid, lst)
    }

    priv fn _binary(self, b: unsafe *BinaryOperatorExpr) -> Doc {
        var k   = b->op_token.kind
        var _op = self._tok(b->op_token)
        var p   = infix_prec(k)

        // `<` / `>` / `>>` glued to a neighbour: maybe a generic the parser
        // read as comparisons (sema turns those into calls). As written, so
        // a misparse can never gain spaces.
        if k == TokenKind::OpLess || k == TokenKind::OpGreater || k == TokenKind::OpGreaterGreater {
            var os = b->op_token.range.start.raw()
            var oe = b->op_token.range.end.raw()
            var pv = self._sig_before(os)
            var nx = self._sig_after(oe)
            var glued = pv < self.toks.size() && self.toks[pv].end == os
                || nx < self.toks.size() && self.toks[nx].start == oe
            if glued {
                return self._ev(b)
            }
        }

        if k == TokenKind::OpAmpAmp || k == TokenKind::OpPipePipe {
            var xs  = cxx::std::vector<unsafe *Expr>()
            var ops = cxx::std::vector<string>()
            self._flatten(b->lhs, k, unsafe &xs, unsafe &ops)
            ops.push_back(_op)
            self._flatten(b->rhs, k, unsafe &xs, unsafe &ops)

            // rule 4.6: break BEFORE every operator of the chain
            var tail = cxx::std::vector<Doc>()
            for var i: usize = 1; i < xs.size(); ++i {
                tail.push_back(Doc::line())
                tail.push_back(Doc::text(ops[i - 1] + " "))
                tail.push_back(
                    self.fxc(
                        xs[i],
                        true,
                        PCtx { kind: 1, prec: p, right: true },
                    ),
                )
            }

            return Doc::group(
                Doc::concat2(
                    self.fxc(
                        xs[0],
                        true,
                        PCtx { kind: 1, prec: p, right: false },
                    ),
                    Doc::indent(Doc::concat(tail)),
                ),
            )
        }

        var l = self.fxc(b->lhs, true, PCtx { kind: 1, prec: p, right: false })
        var r = self.fxc(b->rhs, true, PCtx { kind: 1, prec: p, right: true })
        if _op == ".*" || _op == "->*" || _op == "?.*" || _op == "?->*" {
            return Doc::concat3(l, Doc::text(_op), r)
        }

        return Doc::concat3(l, Doc::text(" " + _op + " "), r)
    }

    /// Operands of a run of one logical operator, unparenthesized ones only.
    priv fn _flatten(self,
                     e:   unsafe *Expr,
                     k:   TokenKind,
                     xs:  unsafe *cxx::std::vector<unsafe *Expr>,
                     ops: unsafe *cxx::std::vector<string>) {
        var unsafe *b = dyn_cast<BinaryOperatorExpr>(e)
        if b != &null
            && b->op_token.kind == k
            && !self._wrapped(e)
            && !self._comment_in(self._es(e), self._ee(e))
            && !self._macro_in(self._es(e), self._ee(e)) {
            self._flatten(b->lhs, k, xs, ops)
            ops->push_back(self._tok(b->op_token))
            self._flatten(b->rhs, k, xs, ops)
            return
        }

        xs->push_back(e)
    }
}

/// Index of \p needle in \p hay, or hay.size().
pub fn find_str(hay: string, needle: string) -> usize {
    var n = hay.size()
    var m = needle.size()
    if m == 0 || m > n {
        return n
    }

    for var i: usize = 0; i + m <= n; ++i {
        var ok = true
        for var j: usize = 0; j < m; ++j {
            if hay[i + j] != needle[j] {
                ok = false
                break
            }
        }

        if ok {
            return i
        }
    }

    return n
}

/// Byte-wise ascending, stable (insertion: these lists are short).
pub fn sort_strings(xs: unsafe *cxx::std::vector<string>) {
    for var i: usize = 1; i < xs->size(); ++i {
        var j = i
        while j > 0 && (*xs)[j] < (*xs)[j - 1] {
            var t = (*xs)[j]
            (*xs)[j]     = (*xs)[j - 1]
            (*xs)[j - 1] = t
            j -= 1
        }
    }
}
