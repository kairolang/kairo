/// --- The Kairo Project ------------------------- Token/TokenPrinter.k --- ///
///
///   Prints a token stream in colored, aligned columns for lexer debugging.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/SmallVector.h"
ffi "c++" import "Native/KShims.hh"

import Lexer::Immediate::{
    Immediate,
    ImmediateTable,
}
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Macro::Sentinel::MacroSentinel
import Support::EvalHash::to_hex_string
import Support::FlagSet::FlagSet
import Token::Token::Token
import Token::TokenBuffer::TokenBuffer
import Token::TokenCacheManager::TokenCacheManager
import Token::TokenKind::{
    TokenKind,
    is_annotation,
    is_builtin,
    is_keyword,
    is_literal,
    is_operator,
    is_punctuator,
    token_kind_to_readable_string,
}
import Token::TokenText::{
    TokenText,
    sentinel_text,
    unwrap_expansion,
}
import std::io

/// \brief ANSI SGR escape sequences. all empty-stringed when color is disabled.
pub class Sgr {
    pub var reset: string = ""
    pub var dim:   string = ""
    pub var bold:  string = ""

    pub var gutter: string = "" ///< token index "[N]"
    pub var kind:   string = "" ///< default token-kind name color
    pub var text:   string = "" ///< the spelled token text
    pub var range:  string = "" ///< "@ [start, end)"
    pub var field:  string = "" ///< imm sub-field label
    pub var fvalue: string = "" ///< imm sub-field value

    pub var kw:      string = "" ///< keywords
    pub var opr:     string = "" ///< operators / punctuators
    pub var lit:     string = "" ///< literals
    pub var ty:      string = "" ///< primitive types / builtins
    pub var ident:   string = "" ///< identifiers
    pub var comment: string = "" ///< comments
    pub var macro_:  string = "" ///< macro-expansion markers
    pub var err:     string = "" ///< error tokens

    fn Sgr(self) { }

    fn Sgr(self, enable: bool) {
        if !enable { // everything stays "" -> plain output
            return
        }

        self.reset = "\x1b[0m"
        self.dim   = "\x1b[2m"
        self.bold  = "\x1b[1m"

        self.gutter = "\x1b[38;5;245m" // [N] readable, not bright
        self.kind   = "\x1b[38;5;75m"  // blue fallback kind
        self.text   = "\x1b[38;5;252m" // spelled text, near-white
        self.range  = "\x1b[38;5;252m" // muted teal NOT gray
        self.field  = "\x1b[38;5;108m" // muted green labels
        self.fvalue = "\x1b[38;5;180m" // tan values

        self.kw      = "\x1b[38;5;204m"   // pink   keywords
        self.opr     = "\x1b[38;5;215m"   // orange operators / punct
        self.lit     = "\x1b[38;5;114m"   // green  literals
        self.ty      = "\x1b[38;5;81m"    // cyan   types
        self.ident   = "\x1b[38;5;117m"   // l.blue identifiers
        self.comment = "\x1b[38;5;245m"   // comments desaturated but readable
        self.macro_  = "\x1b[38;5;177m"   // purple macros
        self.err     = "\x1b[1;38;5;203m" // red    errors
    }
}

pub class TokenPrinter {
    priv var _tcm:   unsafe *TokenCacheManager
    priv var _sm:    unsafe *SourceManager
    priv var _sgr:   Sgr
    priv var _color: bool                      = false

    /// \param sm      source manager for text resolution
    /// \param imm_tbl immediate table for the file being printed (may be null)
    fn TokenPrinter(self, tcm: unsafe *TokenCacheManager) {
        self._tcm   = tcm
        self._sm    = tcm->get_source_manager()
        self._color = self._detect_tty()
        self._sgr   = Sgr(self._color)
    }

    /// \param sm      source manager for text resolution
    /// \param imm_tbl immediate table for the file being printed (may be null)
    /// \param no_color honors DiagnosticOptions.no_color; when false, still
    ///        requires a TTY before emitting escapes.
    pub fn TokenPrinter(self, tcm: unsafe *TokenCacheManager, no_color: bool) {
        self._tcm   = tcm
        self._sm    = tcm->get_source_manager()
        self._color = !no_color && self._detect_tty()
        self._sgr   = Sgr(self._color)
    }

    priv fn _detect_tty(self) -> bool {
        var result: i32 = 0
        result = isatty(1) // STDOUT_FILENO
        return result != 0
    }

    /// \brief left indent for a given nesting depth.
    ///        2 leading spaces + 4 per level, matching the "  [N]" gutter.
    priv fn _indent(self, depth: usize) -> string {
        var out: string
        out += "  "
        for var i: usize = 0; i < depth; ++i {
            out += "    "
        }

        return out
    }

    /// \brief prints the whole stream with a header.
    pub fn print_stream(self, tokens: unsafe *(TokenBuffer<512>), const path: string) {
        var s = self._sgr

        var header: string
        header += s.bold
        header += f"-- token stream: {path} "
        header += s.reset
        header += s.field
        header += f"({tokens->size()} tokens) --"
        header += s.reset
        io::println(f"{header}")

        for var i: usize = 0; i < tokens->size(); ++i {
            self._print_token_at(i, tokens->get(i), 0)
        }
    }

    /// \brief prints a single top-level token (depth 0).
    fn print_token(self, idx: usize, tok: unsafe *Token) {
        self._print_token_at(idx, tok, 0)
    }

    /// \brief prints a token line plus any imm detail, at a given nesting depth.
    /// \param depth 0 = top-level file token, >0 = inside an f-string hole.
    priv fn _print_token_at(self, idx: usize, tok: unsafe *Token, depth: usize) {
        var s   = self._sgr
        var pad = self._indent(depth)

        /// # resolve display kind / imm / range, unwrapping macro expansion
        var        kind      = tok->kind
        var        imm       = tok->imm
        var        tok_range = tok->range
        var unsafe *tbl      = self._tcm->get_imm_table_for_token(*tok)
        var        is_macro  = false

        if tok->kind == TokenKind::TkMacroExpand
            && tok->imm < (MacroSentinel::Threshold as u32)
            && tbl != &null {
            var u = unwrap_expansion(*tok, self._tcm)
            kind      = u.kind
            imm       = u.imm
            tok_range = u.def_range
            tbl       = u.tbl
            is_macro  = u.depth > 0
        }

        /// # gutter: [N]
        var line: string
        line += pad
        line += s.gutter
        line += f"[{idx}]"
        line += s.reset
        line += " "

        /// # error token: imm is the *expected* TokenKind, not an imm index.
        if tok->kind == TokenKind::TkError {
            line += s.err
            line += "error"
            line += s.reset
            line += " "
            line += s.field
            line += "expected "
            line += s.reset
            line += s.err
            line += f"`{token_kind_to_readable_string((tok->imm as TokenKind))}`"
            line += s.reset
            line += " "
            line += self._fmt_range(tok->range)
            io::println(f"{line}")
            return
        }

        /// # macro sentinel: imm >= Threshold means a builtin marker, no table
        if tok->kind == TokenKind::TkMacroExpand && tok->imm >= (MacroSentinel::Threshold as u32) {
            var sentinel = sentinel_text(tok->imm)
            line += s.macro_
            line += "macro-sentinel"
            line += s.reset
            line += " "
            line += s.macro_
            line += f"{sentinel}"
            line += s.reset
            line += " "
            line += self._fmt_range(tok->range)
            io::println(f"{line}")
            return
        }

        /// # normal token: colored kind, spelled text, range
        var kind_color = self._color_for_kind(kind)

        line += kind_color
        line += f"{token_kind_to_readable_string(kind)}"
        line += s.reset

        if is_macro {
            line += " "
            line += s.macro_
            line += "(macro)"
            line += s.reset
        }

        line += " "
        line += kind_color
        line += f"'{(*TokenText::resolve(*tok, self._tcm).get_text())}'"
        line += s.reset
        line += " "
        line += self._fmt_range(tok->range)
        io::println(f"{line}")

        /// # imm detail sub-line(s)
        self._print_imm_detail(*tok, depth)

        /// # if macro, also show where it expanded from
        if is_macro {
            var sub: string
            sub += self._indent(depth)
            sub += "      "
            sub += s.field
            sub += "expanded-at: "
            sub += s.reset
            sub += s.fvalue
            sub += f"{tok->range}"
            sub += s.reset
            io::println(f"{sub}")
        }
    }

    /// \brief renders "@ [start, end)" in range color.
    priv fn _fmt_range(self, range: SourceRange) -> string {
        var s           = self._sgr
        var out: string
        out += s.range
        out += f"@ {range}"
        out += s.reset
        return out
    }

    /// \brief picks a color from the token's class using Token::Type predicates,
    ///        so colors stay correct as new kinds are added.
    priv fn _color_for_kind(self, kind: TokenKind) -> string {
        var s = self._sgr

        if kind == TokenKind::AtComment {
            return s.comment
        }

        if kind == TokenKind::LitIdentifier {
            return s.ident
        }

        if kind == TokenKind::TkWhitespace {
            return s.range
        }

        if is_keyword(kind) {
            return s.kw
        }

        if is_literal(kind) {
            return s.lit
        }

        if is_builtin(kind) {
            return s.ty
        }

        if is_annotation(kind) { // primitive types are annotations
            return s.ty
        }

        if is_operator(kind) {
            return s.opr
        }

        if is_punctuator(kind) {
            return s.opr
        }

        return s.kind // fallback
    }

    // sentinel display text comes from Token::TokenText::sentinel_text
    // one vocabulary for dumps, diagnostics, and resolve().

    /// \brief emits an indented detail line for tokens that own an
    ///        immediate-table entry. no-op for everything else.
    priv fn _print_imm_detail(self, tok: Token, depth: usize) {
        var        kind = tok.kind
        var        imm  = tok.imm
        var unsafe *tbl = self._tcm->get_imm_table_for_token(tok)
        if tbl == &null {
            return
        }

        if imm == u32::MAX {
            return
        }

        if kind == TokenKind::LitInt {
            self._print_int_detail(imm, tbl, depth)
        } else if kind == TokenKind::LitFloat {
            self._print_float_detail(imm, tbl, depth)
        } else if kind == TokenKind::LitString {
            self._print_string_detail(imm, tbl, depth)
        } else if kind == TokenKind::LitChar {
            self._print_char_detail(imm, tbl, depth)
        }
    }

    /// \brief begins a detail line: indent + "`- " connector + label.
    priv fn _field_line(self, const label: string, depth: usize) -> string {
        var s   = self._sgr
        var out = self._indent(depth)
        out += "      "
        out += s.range
        out += "`- "
        out += s.reset
        out += s.field
        out += label
        out += s.reset
        return out
    }

    priv fn _print_int_detail(self, imm: u32, tbl: unsafe *ImmediateTable, depth: usize) {
        var unsafe *d = tbl->get<Immediate::IntData>(imm)
        var        s  = self._sgr

        var is_unsigned = (d->flags & 0b00000001) != 0
        var is_negative = (d->flags & 0b00000010) != 0
        var is_big      = (d->flags & 0b00000100) != 0
        var has_suffix  = (d->flags & 0b00001000) != 0
        var has_prefix  = (d->flags & 0b00010000) != 0
        var sign        = if is_unsigned => "u" else => "i"

        var line: string
        line += self._field_line("int", depth)
        line += " "
        line += s.fvalue

        if is_big {
            // value lives in ImmBigInt; lo/hi are a truncated convenience copy.
            line += f"big {sign}{d->bits}"
            line += s.reset
            line += s.field
            line += f" (lo=0x{to_hex_string(((d->value_lo) as usize))} hi=0x{to_hex_string(((d->value_hi) as usize))}, truncated)"
            line += s.reset
        } else if d->value_hi != 0 {
            line += f"{sign}{d->bits} = 0x{to_hex_string(((d->value_hi) as usize))}:{to_hex_string(((d->value_lo) as usize))}"
            line += s.reset
        } else {
            line += f"{sign}{d->bits} = {d->value_lo}"
            line += s.reset
            line += s.field
            line += f" (0x{to_hex_string(((d->value_lo) as usize))})"
            line += s.reset
        }

        line += s.field
        line += f"  base={(d->base) as u64}"
        if has_prefix {
            line += f" prefix='{self._sm->get_text(d->prefix)}'"
        }

        if has_suffix {
            line += f" suffix='{self._sm->get_text(d->suffix)}'"
        }

        if is_negative {
            line += " neg"
        }

        line += s.reset
        io::println(f"{line}")
    }

    priv fn _print_float_detail(self, imm: u32, tbl: unsafe *ImmediateTable, depth: usize) {
        var unsafe *d = tbl->get<Immediate::FloatData>(imm)
        var        s  = self._sgr

        var has_exponent = (d->flags & 0b00000001) != 0
        var is_negative  = (d->flags & 0b00000010) != 0
        var is_hex       = (d->flags & 0b00000100) != 0
        var use_big      = (d->flags & 0b00001000) != 0
        var has_suffix   = (d->flags & 0b00010000) != 0

        var line: string
        line += self._field_line("float", depth)
        line += " "
        line += s.fvalue
        line += f"f{d->bits} = {d->value_ieee as f64}"
        line += s.reset

        line += s.field
        line += f"  base={(d->base) as u64}"
        if has_exponent {
            line += " exp"
        }

        if is_hex {
            line += " hex"
        }

        if use_big {
            line += " bigfloat"
        }

        if is_negative {
            line += " neg"
        }

        if has_suffix {
            line += f" suffix='{self._sm->get_text(d->suffix)}'"
        }

        line += s.reset
        io::println(f"{line}")
    }

    priv fn _print_string_detail(self, imm: u32, tbl: unsafe *ImmediateTable, depth: usize) {
        var unsafe *d = tbl->get<Immediate::StringData>(imm)
        var        s  = self._sgr

        var body_text = tbl->string_text(imm, self._sm)            // owned bytes when synthesized
        var kind_str  = self._text_prefix_kind_str(d->prefix_kind)

        var line: string
        line += self._field_line("string", depth)
        line += " "
        line += s.fvalue
        line += f"\"{body_text}\" "
        line += s.reset

        line += s.field
        line += f"  kind={kind_str} interp-exprs={d->exprs.size()}"
        if d->next != u32::MAX {
            line += f" next={d->next}"
        }

        line += s.reset
        io::println(f"{line}")

        self._print_interp_exprs(&d->exprs, depth)
    }

    priv fn _print_char_detail(self, imm: u32, tbl: unsafe *ImmediateTable, depth: usize) {
        var unsafe *d = tbl->get<Immediate::CharData>(imm)
        var        s  = self._sgr

        var body_text = self._sm->get_text(d->body)
        var kind_str  = self._text_prefix_kind_str(d->prefix_kind)

        var line: string
        line += self._field_line("char", depth)
        line += " "
        line += s.fvalue
        line += f"'{body_text}'"
        line += s.reset

        line += s.field
        line += f"  kind={kind_str} interp-exprs={d->exprs.size()}"
        line += s.reset
        io::println(f"{line}")

        self._print_interp_exprs(&d->exprs, depth)
    }

    /// \brief prints each f-string interpolation hole as a nested token stream,
    ///        one nesting level deeper than the owning string/char.
    priv fn _print_interp_exprs(
        self,
        @inout exprs: llvm::SmallVector<(unsafe *TokenBuffer<16>, SourceRange), 4>,
        depth:        usize,
    ) {
        var s = self._sgr

        for var e: usize = 0; e < exprs.size(); ++e {
            var unsafe *buf       = exprs[e].0
            var        hole_range = exprs[e].1

            var head: string
            head += self._field_line(f"expr[{e}]", depth)
            head += " "
            head += self._fmt_range(hole_range)
            io::println(f"{head}")

            if buf == &null {
                var warn: string
                warn += self._field_line("<null buffer>", depth + 1)
                io::println(f"{warn}")
                continue
            }

            for var i: usize = 0; i < buf->size(); ++i {
                self._print_token_at(i, buf->get(i), depth + 1)
            }
        }
    }

    priv fn _text_prefix_kind_str(self, k: FlagSet<Immediate::TextPrefixKind, u8>) -> string {
        if k.empty() {
            return "none"
        }

        var s: string = ""
        if k.has(Immediate::TextPrefixKind::Raw) {
            s = s + "r"
        }

        if k.has(Immediate::TextPrefixKind::Format) {
            s = s + "f"
        }

        return s
    }
}
