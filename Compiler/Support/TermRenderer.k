/// --- The Kairo Project ----------------------- Support/TermRenderer.k --- ///
///
///   TermRenderer: renders markdown for a terminal, optionally in color.
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
ffi "c++" import "clang/Basic/IdentifierTable.h"
ffi "c++" import "clang/Basic/LangOptions.h"
ffi "c++" import "clang/Basic/LangStandard.h"
ffi "c++" import "clang/Basic/TokenKinds.h"
ffi "c++" import "clang/Frontend/FrontendOptions.h"
ffi "c++" import "clang/Lex/Lexer.h"
ffi "c++" import "clang/Lex/Token.h"
ffi "c++" import "llvm/TargetParser/Triple.h"
ffi "c++" import "vector"
ffi "c++" import "string"

import Support::Ascii::{
    ascii_byte, find, is_digit, is_ident_char, is_ident_start, trim, utf8_next,
}
import Support::EvalHash::compute_hash
import Token::TokenKind::{
    TokenKind,
    is_valid_token_kind,
    token_kind_to_readable_string,
}
import std::io

pub class TermRenderer {
    priv var _color: bool
    priv var _width: u32

    const RESET:     string = "\x1b[0m"
    const BOLD:      string = "\x1b[1m"
    const DIM:       string = "\x1b[2m"
    const UNDERLINE: string = "\x1b[4m"
    const RED:       string = "\x1b[31m"
    const YELLOW:    string = "\x1b[33m"
    const CYAN:      string = "\x1b[36m"
    const GREEN:     string = "\x1b[32m"
    const MAGENTA:   string = "\x1b[35m"
    const WHITE:     string = "\x1b[37m"
    const BG_GRAY:   string = "\x1b[48;5;236m"

    // Syntax highlighting palette (truecolor)
    const HL_KEYWORD:   string = "\x1b[38;2;250;121;112m" // #fa7970
    const HL_TYPE:      string = "\x1b[38;2;250;163;86m"  // #faa356
    const HL_STRING:    string = "\x1b[38;2;124;227;139m" // #7ce38b
    const HL_NUMBER:    string = "\x1b[38;2;162;210;251m" // #a2d2fb
    const HL_FUNC:      string = "\x1b[38;2;206;165;251m" // #cea5fb
    const HL_COMMENT:   string = "\x1b[38;2;137;146;155m" // #89929b
    const HL_ATTRIBUTE: string = "\x1b[38;2;124;227;139m" // #7ce38b

    struct CodeBlockInfo {
        var lang: string
        var file: string
    }

    fn TermRenderer(self) {
        var color: bool = true
        var width: u32  = 80
        self._color = color
        self._width = width
    }

    pub fn TermRenderer(self, color: bool, width: u32 = 80) {
        self._color = color
        self._width = width
    }

    fn style(self, code: string) -> string {
        return if self._color => (code) else => ""
    }

    /// The longest prefix of `s` that fits in `max_cols` terminal columns,
    /// measured as display_width measures; a zero-width character after the
    /// last one that fits stays with it.
    priv fn clip_to_width(self, const s: string, max_cols: u32) -> string {
        var w: u32   = 0
        var i: usize = 0
        while i < s.size() {
            var len: usize = 0
            var cols       = self.char_width(s, i, &len)
            if w + cols > max_cols {
                break
            }

            w += cols
            i += len
        }

        return s.subslice(0, i)
    }

    pub fn render(self, const text: string) -> string {
        var lines           = self.split_lines(text)
        var out             = string()
        var in_code_block   = false
        var code_block_info = Self::CodeBlockInfo()

        var i: usize = 0
        while i < lines.size() {
            var line    = lines[i].copy()
            var trimmed = trim(line)

            /// ## fenced code block
            if trimmed.starts_with("```") {
                if in_code_block {
                    // closing fence - draw bottom border
                    out += self.style(self.DIM.copy())
                    out += "  └"
                    for _ in (0 as u32) .. self._width - 4 {
                        out += "-"
                    }

                    out += "┘"
                    out += self.style(self.RESET.copy())
                    out += "\n"
                    in_code_block = false
                    i += 1
                    continue
                }

                // opening fence
                in_code_block   = true
                code_block_info = self.parse_fence(trimmed)

                // draw top border with lang/file
                out += self.style(self.DIM.copy())
                out += "  ┌"

                var header = string()
                if code_block_info.lang.size() > 0 {
                    header += " " + code_block_info.lang + " "
                }

                if code_block_info.file.size() > 0 {
                    if header.size() > 0 {
                        header += "· "
                    } else {
                        header += " "
                    }

                    header += code_block_info.file
                    header += " "
                }

                if header.size() > 0 {
                    out += "-"
                    out += self.style(self.RESET.copy() + self.BOLD)
                    out += header
                    out += self.style(self.RESET.copy() + self.DIM)
                    var remaining = self._width - 3 - (header.size() as u32) - 2
                    for _ in (0 as u32) .. remaining {
                        out += "-"
                    }
                } else {
                    for _ in (0 as u32) .. self._width - 4 {
                        out += "-"
                    }
                }

                out += "┐"
                out += self.style(self.RESET.copy())
                out += "\n"
                i += 1
                continue
            }

            if in_code_block {
                // The text's columns between `│ ` and `│`, one kept free so a
                // line that fills them still has a space before the border.
                var inner   = self._width - 5
                var clipped = self.clip_to_width(line, inner - 1)

                out += self.style(self.DIM.copy())
                out += "  │ "
                out += self.style(self.RESET.copy())
                out += self.highlight(clipped.copy(), code_block_info.lang)

                var used = self.display_width(clipped)
                for _ in (0 as u32) .. inner - used {
                    out += " "
                }

                out += self.style(self.DIM.copy())
                out += "│"
                out += self.style(self.RESET.copy())
                out += "\n"
                i += 1
                continue
            }

            if trimmed.size() == 0 {
                out += "\n"
                i += 1
                continue
            }

            var heading_level = self.heading_level(trimmed)
            if heading_level > 0 {
                var heading_text = trim(
                    self.after_prefix(trimmed, heading_level),
                )

                match heading_level {
                    case 1 {
                        out += self.style(self.BOLD.copy() + self.UNDERLINE)
                        out += heading_text
                        out += self.style(self.RESET.copy())
                    } case 2 {
                        out += self.style(self.BOLD.copy())
                        out += heading_text
                        out += self.style(self.RESET.copy())
                    } case 3 {
                        out += self.style(self.BOLD.copy() + self.DIM)
                        out += heading_text
                        out += self.style(self.RESET.copy())
                    } default {
                        out += self.style(self.DIM.copy())
                        out += heading_text
                        out += self.style(self.RESET.copy())
                    }
                }

                out += "\n"
                i += 1
                continue
            }

            if trimmed.starts_with("- ") {
                var content = trimmed.subslice(2, trimmed.size() - 2)
                out += self.wrap_inline(content, 4, "  • ")
                i += 1
                continue
            }

            var num_prefix = self.numbered_prefix(trimmed)
            if num_prefix.size() > 0 {
                var content = trimmed.subslice(
                    num_prefix.size(),
                    trimmed.size() - num_prefix.size(),
                )

                var pad = string()
                for _ in (0 as usize) .. ((num_prefix.size() + 2)) {
                    pad += " "
                }

                out += self.wrap_inline(
                    content,
                    pad.size() as u32,
                    "  " + num_prefix,
                )

                i += 1
                continue
            }

            out += self.wrap_inline(trimmed, 2, "  ")
            i += 1
        }

        return out
    }

    /// Combining marks, zero-width format characters (ZWSP, ZWNJ, ZWJ, BOM)
    /// and variation selectors.
    priv fn is_zero_width(self, cp: u32) -> bool {
        return cp >= 0x300 && cp <= 0x36F
            || cp >= 0x483 && cp <= 0x489
            || cp >= 0x591 && cp <= 0x5BD
            || cp >= 0x610 && cp <= 0x61A
            || cp >= 0x64B && cp <= 0x65F
            || cp >= 0x1AB0 && cp <= 0x1AFF
            || cp >= 0x1DC0 && cp <= 0x1DFF
            || cp >= 0x200B && cp <= 0x200F
            || cp >= 0x2028 && cp <= 0x202E
            || cp >= 0x2060 && cp <= 0x2064
            || cp >= 0x20D0 && cp <= 0x20FF
            || cp >= 0xFE00 && cp <= 0xFE0F
            || cp >= 0xFE20 && cp <= 0xFE2F
            || cp == 0xFEFF
            || cp >= 0xE0100 && cp <= 0xE01EF
    }

    /// East Asian Wide and Fullwidth ranges (CJK, Hangul, fullwidth forms, emoji).
    priv fn is_wide(self, cp: u32) -> bool {
        return cp >= 0x1100 && cp <= 0x115F
            || cp >= 0x231A && cp <= 0x231B
            || cp >= 0x2329 && cp <= 0x232A
            || cp >= 0x23E9 && cp <= 0x23EC
            || cp == 0x23F0
            || cp == 0x23F3
            || cp >= 0x25FD && cp <= 0x25FE
            || cp >= 0x2614 && cp <= 0x2615
            || cp >= 0x2648 && cp <= 0x2653
            || cp == 0x267F
            || cp == 0x2693
            || cp == 0x26A1
            || cp >= 0x26AA && cp <= 0x26AB
            || cp >= 0x26BD && cp <= 0x26BE
            || cp >= 0x26C4 && cp <= 0x26C5
            || cp == 0x26CE
            || cp == 0x26D4
            || cp == 0x26EA
            || cp >= 0x26F2 && cp <= 0x26F3
            || cp == 0x26F5
            || cp == 0x26FA
            || cp == 0x26FD
            || cp == 0x2705
            || cp >= 0x270A && cp <= 0x270B
            || cp == 0x2728
            || cp == 0x274C
            || cp == 0x274E
            || cp >= 0x2753 && cp <= 0x2755
            || cp == 0x2757
            || cp >= 0x2795 && cp <= 0x2797
            || cp == 0x27B0
            || cp == 0x27BF
            || cp >= 0x2B1B && cp <= 0x2B1C
            || cp == 0x2B50
            || cp == 0x2B55
            || cp >= 0x2E80 && cp <= 0x303E
            || cp >= 0x3041 && cp <= 0x33FF
            || cp >= 0x3400 && cp <= 0x4DBF
            || cp >= 0x4E00 && cp <= 0x9FFF
            || cp >= 0xA000 && cp <= 0xA4CF
            || cp >= 0xA960 && cp <= 0xA97F
            || cp >= 0xAC00 && cp <= 0xD7A3
            || cp >= 0xF900 && cp <= 0xFAFF
            || cp >= 0xFE10 && cp <= 0xFE19
            || cp >= 0xFE30 && cp <= 0xFE6F
            || cp >= 0xFF00 && cp <= 0xFF60
            || cp >= 0xFFE0 && cp <= 0xFFE6
            || cp >= 0x16FE0 && cp <= 0x16FE4
            || cp >= 0x17000 && cp <= 0x18CFF
            || cp >= 0x1B000 && cp <= 0x1B2FF
            || cp == 0x1F004
            || cp == 0x1F0CF
            || cp == 0x1F18E
            || cp >= 0x1F191 && cp <= 0x1F19A
            || cp >= 0x1F200 && cp <= 0x1F251
            || cp >= 0x1F300 && cp <= 0x1F64F
            || cp >= 0x1F680 && cp <= 0x1F6FF
            || cp >= 0x1F7E0 && cp <= 0x1F7EB
            || cp >= 0x1F90C && cp <= 0x1F9FF
            || cp >= 0x1FA70 && cp <= 0x1FAFF
            || cp >= 0x20000 && cp <= 0x2FFFD
            || cp >= 0x30000 && cp <= 0x3FFFD
    }

    /// Terminal columns `s` occupies: UTF-8 is decoded, an East Asian
    /// Wide / Fullwidth codepoint is 2 columns, a combining mark, zero-width
    /// format character (ZWJ, ZWSP, BOM) or variation selector is 0, anything
    /// else 1. Each byte of invalid UTF-8 counts as 1, so a malformed line
    /// still advances.
    priv fn display_width(self, const s: string) -> u32 {
        var w: u32   = 0
        var i: usize = 0
        while i < s.size() {
            var len: usize = 0
            w += self.char_width(s, i, &len)
            i += len
        }

        return w
    }

    /// The columns of the character at byte `i` of `s` (see
    /// display_width), and in `len` its length in bytes, at least 1.
    priv fn char_width(self, const s: string, i: usize, @inout len: usize) -> u32 {
        var n       = s.size()
        var b0      = ((s.data()[i]) as u32)
        var cp: u32 = 0
        len = 0
        if b0 < 0x80 {
            len = 1
            cp  = b0
        } else if (b0 & 0xE0) == 0xC0 && b0 >= 0xC2 {
            len = 2
            cp  = b0 & 0x1F
        } else if (b0 & 0xF0) == 0xE0 {
            len = 3
            cp  = b0 & 0x0F
        } else if (b0 & 0xF8) == 0xF0 && b0 <= 0xF4 {
            len = 4
            cp  = b0 & 0x07
        }

        var ok = len > 0 && i + len <= n
        for var k: usize = 1; ok && k < len; ++k {
            var bk = ((s.data()[i + k]) as u32)
            if (bk & 0xC0) != 0x80 {
                ok = false
            } else {
                cp = cp << 6 | bk & 0x3F
            }
        }

        // overlong encodings and surrogates are invalid too
        if ok && len == 3 && (cp < 0x800 || cp >= 0xD800 && cp <= 0xDFFF) {
            ok = false
        }

        if ok && len == 4 && (cp < 0x10000 || cp > 0x10FFFF) {
            ok = false
        }

        if !ok {
            len = 1
            return 1
        }

        if self.is_zero_width(cp) {
            return 0
        }

        return if self.is_wide(cp) => (2) else => 1
    }

    fn wrap_inline(self, const text: string, indent: u32, const first_prefix: string) -> string {
        var out      = string()
        var col: u32 = 0
        var pad      = string()
        for _ in (0 as u32) .. indent {
            pad += " "
        }

        out += first_prefix
        col = self.display_width(first_prefix)

        var i: usize = 0
        while i < text.size() {
            if text.data()[i] == ('`' as u8) {
                // No closing backtick on this line: the backtick is text.
                var close = find(text, "`", i + 1)
                if close != usize::MAX {
                    var code_text = text.subslice(i + 1, close - i - 1)
                    var styled = self.style(self.CYAN.copy()) + code_text + self.style(
                        self.RESET.copy(),
                    )

                    if col + self.display_width(code_text) + 2 > self._width && col > indent {
                        out += "\n" + pad
                        col = indent
                    }

                    out += styled
                    col += self.display_width(code_text)
                    i = close + 1
                    continue
                }
            }

            if text.data()[i] == (' ' as u8) {
                // lookahead for next word length
                var next_end = self.find_word_end(text, i + 1)
                var next_len = ((next_end - (i + 1)) as u32)

                if col + 1 + next_len > self._width && col > indent {
                    out += "\n" + pad
                    col = indent
                } else {
                    out += " "
                    col += 1
                }

                i += 1
                continue
            }

            // One character, all its bytes (a cut inside one traps); `col`
            // counts bytes.
            var e = utf8_next(text, i)
            out += text[i..e]
            col += (e - i) as u32
            i = e
        }

        out += "\n"
        return out
    }

    /// # Syntax highlighting

    priv fn is_upper(self, c: u8) -> bool {
        return c >= ('A' as u8) && c <= ('Z' as u8)
    }

    /// A Kairo word, which may also carry `#` (`#type`).
    priv fn is_word_start(self, c: u8) -> bool {
        return is_ident_start(c) || c == ('#' as u8)
    }

    priv fn is_word_char(self, c: u8) -> bool {
        return is_ident_char(c) || c == ('#' as u8)
    }

    // The same tests for a `char`, the string subscript of the other
    // builtin library; a character past ASCII is in none.
    priv fn is_upper(self, c: char) -> bool {
        return self.is_upper(ascii_byte(c))
    }

    priv fn is_word_start(self, c: char) -> bool {
        return self.is_word_start(ascii_byte(c))
    }

    priv fn is_word_char(self, c: char) -> bool {
        return self.is_word_char(ascii_byte(c))
    }

    /// The kind `word` lexes as, or TkUnknown for a plain identifier. The
    /// lexer's own test (a word token's kind is its spelling hash), so the
    /// highlighter follows the token table instead of keeping a word list;
    /// the spelling compare keeps a hash collision from reading as a keyword.
    priv fn word_kind(self, const word: string) -> TokenKind {
        var h = compute_hash(unsafe &word) as u32
        if !is_valid_token_kind(h) {
            return TokenKind::TkUnknown
        }

        var kind = h as TokenKind
        if word != token_kind_to_readable_string(kind) {
            return TokenKind::TkUnknown
        }

        return kind
    }

    /// Words coloured as values rather than keywords.
    priv fn is_value_word(self, kind: TokenKind) -> bool {
        match kind {
            case TokenKind::KwTrue, TokenKind::KwFalse, TokenKind::LitNull, TokenKind::KwSelf,
                 TokenKind::BiSelf {
                return true
            } default {
                return false
            }
        }
    }

    priv fn is_keyword(self, const word: string, kind: TokenKind) -> bool {
        // a library type, not a token, coloured with the primitive words.
        if word == "string" {
            return true
        }

        return kind != TokenKind::TkUnknown
    }

    priv fn highlight(self, line: string, const lang: string) -> string {
        if !self._color {
            return line
        }

        if lang == "text" || lang == "txt" || lang == "plain" {
            return line
        }

        var cl = TermRenderer::clang_language(lang)
        // Languages clang takes but does not lex (IR, assembly): plain, not
        // read as Kairo.
        if cl == clang::Language::Asm
            || cl == clang::Language::LLVM_IR
            || cl == clang::Language::CIR {
            return line
        }

        if cl != clang::Language::Unknown {
            return self.highlight_clang(line, cl)
        }

        var out       = string()
        var i:  usize = 0
        var n         = line.size()

        while i < n {
            var c = line.data()[i]

            // whitespace - emit raw, preserves indentation
            if c == (' ' as u8) || c == ('\t' as u8) {
                out.push(c)
                i += 1
                continue
            }

            // line comment
            if c == ('/' as u8) && i + 1 < n && line.data()[i + 1] == ('/' as u8) {
                var rest = line.subslice(i, n - i)
                out += self.style(self.HL_COMMENT.copy()) + rest + self.style(
                    self.RESET.copy(),
                )

                i = n
                continue
            }

            // block comment (same-line only)
            if c == ('/' as u8) && i + 1 < n && line.data()[i + 1] == ('*' as u8) {
                var j = i + 2
                while j + 1 < n
                    && !(line.data()[j] == ('*' as u8) && line.data()[j + 1] == ('/' as u8)) {
                    j += 1
                }

                var end = if (j + 1 < n) => (j + 2) else => n
                var seg = line.subslice(i, end - i)
                out += self.style(self.HL_COMMENT.copy()) + seg + self.style(
                    self.RESET.copy(),
                )

                i = end
                continue
            }

            // raw string  r"..."
            if (c == ('r' as u8) || c == ('R' as u8))
                && i + 1 < n
                && line.data()[i + 1] == ('\x22' as u8) {
                var j = i + 2
                while j < n && line.data()[j] != ('\x22' as u8) {
                    j += 1
                }

                if j < n {
                    j += 1
                }

                var seg = line.subslice(i, j - i)
                out += self.style(self.HL_STRING.copy()) + seg + self.style(
                    self.RESET.copy(),
                )

                i = j
                continue
            }

            // string literal
            if c == ('\x22' as u8) {
                var j = i + 1
                while j < n && line.data()[j] != ('\x22' as u8) {
                    if line.data()[j] == ('\\' as u8) && j + 1 < n {
                        j += 1
                    }

                    j += 1
                }

                if j < n {
                    j += 1
                }

                var seg = line.subslice(i, j - i)
                out += self.style(self.HL_STRING.copy()) + seg + self.style(
                    self.RESET.copy(),
                )

                i = j
                continue
            }

            // char literal
            if c == ('\'' as u8) {
                var j = i + 1
                while j < n && line.data()[j] != ('\'' as u8) {
                    if line.data()[j] == ('\\' as u8) && j + 1 < n {
                        j += 1
                    }

                    j += 1
                }

                if j < n {
                    j += 1
                }

                var seg = line.subslice(i, j - i)
                out += self.style(self.HL_STRING.copy()) + seg + self.style(
                    self.RESET.copy(),
                )

                i = j
                continue
            }

            // number  (handles 0xFF, 0b1010, 1.5, 1e3 prefix)
            if is_digit(c) {
                var j = i
                while j < n
                    && (self.is_word_char(line.data()[j]) || line.data()[j] == ('.' as u8)) {
                    j += 1
                }

                var seg = line.subslice(i, j - i)
                out += self.style(self.HL_NUMBER.copy()) + seg + self.style(
                    self.RESET.copy(),
                )

                i = j
                continue
            }

            // attributes (e.g., @property)
            if c == ('@' as u8) {
                var j = i + 1
                while j < n && self.is_word_char(line.data()[j]) {
                    j += 1
                }

                var seg = line.subslice(i, j - i)
                out += self.style(self.HL_ATTRIBUTE.copy()) + seg + self.style(
                    self.RESET.copy(),
                )

                i = j
                continue
            }

            // identifier / keyword / type / call
            if self.is_word_start(c) {
                var j = i
                while j < n && self.is_word_char(line.data()[j]) {
                    j += 1
                }

                var word = line.subslice(i, j - i)

                // peek next non-space for '(' -> function call
                var k = j
                while k < n && (line.data()[k] == (' ' as u8) || line.data()[k] == ('\t' as u8)) {
                    k += 1
                }

                var is_call = k < n && line.data()[k] == ('(' as u8)

                var kind = self.word_kind(word)

                if self.is_value_word(kind) {
                    out += self.style(self.HL_NUMBER.copy()) + word + self.style(
                        self.RESET.copy(),
                    )
                } else if self.is_keyword(word, kind) {
                    out += self.style(self.HL_KEYWORD.copy()) + word + self.style(
                        self.RESET.copy(),
                    )
                } else if is_call {
                    out += self.style(self.HL_FUNC.copy()) + word + self.style(
                        self.RESET.copy(),
                    )
                } else if self.is_upper(c) {
                    out += self.style(self.HL_TYPE.copy()) + word + self.style(
                        self.RESET.copy(),
                    )
                } else {
                    out += word
                }

                i = j
                continue
            }


            // operators / punctuation - left neutral; one character, all
            // its bytes
            var e = utf8_next(line, i)
            out += line[i..e]
            i = e
        }

        return out
    }

    /// # Clang languages

    /// The clang language a code-block tag or a file extension (no dot)
    /// names, through clang's own extension table (FrontendOptions, where
    /// -x defaults come from) plus the fence tags and header extensions that
    /// table lacks. Unknown for Kairo and anything else clang does not take.
    static fn clang_language(const tag: string) -> clang::Language {
        if tag == "objc" || tag == "objective-c" {
            return clang::Language::ObjC
        }

        if tag == "objc++" || tag == "objective-c++" {
            return clang::Language::ObjCXX
        }

        if tag == "opencl" {
            return clang::Language::OpenCL
        }

        if tag == "cuda" {
            return clang::Language::CUDA
        }

        // clang files headers by driver type, not here. A .h is as often C++
        // as C, and C++ is the superset that colours both.
        if tag == "h"
            || tag == "hh"
            || tag == "H"
            || tag == "hp"
            || tag == "h++"
            || tag == "inl"
            || tag == "ipp"
            || tag == "tcc" {
            return clang::Language::CXX
        }

        return clang::FrontendOptions::getInputKindForExtension(
            kairo::sref(tag),
        ).getLanguage()
    }

    /// One line of a clang language, lexed by clang's raw lexer under that
    /// language's newest standard, so the keyword set is exactly clang's
    /// (C23's `bool`, C++26's `contract_assert`, OpenCL's address spaces,
    /// ObjC's @-keywords). The tables are rebuilt per call: a snippet is a
    /// few lines, and an owned cache would make the renderer unsafe to copy.
    priv fn highlight_clang(self, const line: string, lang: clang::Language) -> string {
        var lo:      clang::LangOptions
        var incs:    cxx::std::vector<cxx::std::string>
        var std_kind                                    = clang::LangStandard::lang_unspecified
        if lang == clang::Language::C || lang == clang::Language::ObjC {
            std_kind = clang::LangStandard::lang_gnu23
        }

        if lang == clang::Language::CXX
            || lang == clang::Language::ObjCXX
            || lang == clang::Language::CUDA
            || lang == clang::Language::HIP {
            std_kind = clang::LangStandard::lang_gnucxx26
        }

        clang::LangOptions::setLangDefaults(
            &lo,
            lang,
            llvm::Triple(),
            &incs,
            std_kind,
        )

        var ids  = clang::IdentifierTable(lo)
        var objc = lang == clang::Language::ObjC || lang == clang::Language::ObjCXX

        // The raw lexer reads one byte past the end, which must be a NUL:
        // a libc++ string's is.
        var buf = kairo::std::to_std_string(line)
        var lx = clang::Lexer(
            clang::SourceLocation(),
            lo,
            buf.data(),
            buf.data(),
            buf.data() + buf.size(),
        )

        lx.SetCommentRetentionState(true)

        var n                      = line.size()
        var out                    = string()
        var pos:      usize        = 0           ///< bytes of `line` already in `out`
        var first                  = true
        var directive              = false       ///< the token after a line-leading `#`
        var held_at                = false       ///< an ObjC `@`, held to join what follows
        var tok:      clang::Token
        while true {
            var last = lx.LexFromRawLexer(&tok)
            if tok.is(clang::tok::eof) {
                break
            }

            var end   = (lx.getCurrentBufferOffset() as usize)
            var len   = (tok.getLength() as usize)
            var start = end - len
            var gap   = line.subslice(pos, start - pos)
            var text  = line.subslice(start, len)
            var kind  = tok.getKind()
            pos = end

            // `@interface`, `@"str"`, `@42`: one token to the eye.
            if held_at {
                held_at = false
                if gap.size() == 0 {
                    if kind == clang::tok::raw_identifier {
                        var *ai = &ids.get(tok.getRawIdentifier())
                        if ai->getObjCKeywordID() != clang::tok::objc_not_keyword {
                            out += self.style(self.HL_KEYWORD.copy()) + "@" + text + self.style(
                                self.RESET.copy(),
                            )

                            first = false
                            if last {
                                break
                            }

                            continue
                        }
                    } else if clang::tok::isLiteral(kind) {
                        var hl = if (kind == clang::tok::numeric_constant) => (self.HL_NUMBER.copy())
                                 else => self.HL_STRING.copy()
                        out += self.style(hl.copy()) + "@" + text + self.style(
                            self.RESET.copy(),
                        )

                        first = false
                        if last {
                            break
                        }

                        continue
                    }
                }

                out += "@"
            }

            out += gap

            if kind == clang::tok::comment {
                out += self.style(self.HL_COMMENT.copy()) + text + self.style(
                    self.RESET.copy(),
                )
            } else if kind == clang::tok::numeric_constant {
                out += self.style(self.HL_NUMBER.copy()) + text + self.style(
                    self.RESET.copy(),
                )
            } else if clang::tok::isLiteral(kind) {
                out += self.style(self.HL_STRING.copy()) + text + self.style(
                    self.RESET.copy(),
                )
            } else if kind == clang::tok::hash && first {
                out += self.style(self.HL_KEYWORD.copy()) + text + self.style(
                    self.RESET.copy(),
                )

                directive = true
                first     = false
                if last {
                    break
                }

                continue
            } else if kind == clang::tok::at && objc {
                held_at = true
            } else if kind == clang::tok::raw_identifier {
                if directive {
                    out += self.style(self.HL_KEYWORD.copy()) + text + self.style(
                        self.RESET.copy(),
                    )

                    // The raw lexer splits `<a/b.h>` into punctuation: the
                    // header name is the rest of the line.
                    if text == "include"
                        || text == "include_next"
                        || text == "import"
                        || text == "embed" {
                        var at = pos
                        while at < n
                            && (line.data()[at] == (' ' as u8) || line.data()[at] == ('\t' as u8)) {
                            at += 1
                        }

                        out += line.subslice(pos, at - pos)
                        if at < n {
                            out += self.style(self.HL_STRING.copy()) + line.subslice(
                                at,
                                n - at,
                            ) + self.style(self.RESET.copy())
                        }

                        pos = n
                        break
                    }
                } else {
                    out += self.clang_word(
                        &ids,
                        &lo,
                        &tok,
                        text.copy(),
                        line,
                        end,
                    )
                }
            } else {
                out += text
            }

            directive = false
            first     = false
            if last {
                break
            }
        }

        if held_at {
            out += "@"
        }

        if pos < n {
            out += line.subslice(pos, n - pos)
        }

        return out
    }

    /// An identifier's colour: literal-valued keywords as values, then
    /// clang's keywords for the language, then the same call / type-name
    /// heuristics the Kairo highlighter uses.
    priv fn clang_word(self,
                       @inout ids: clang::IdentifierTable,
                       @inout lo:  clang::LangOptions,
                       @inout tok: clang::Token,
                       text:       string,
                       const line: string,
                       end:        usize) -> string {
        if text == "true"
            || text == "false"
            || text == "nullptr"
            || text == "this"
            || text == "NULL"
            || text == "nil"
            || text == "self" {
            return self.style(self.HL_NUMBER.copy()) + text + self.style(
                self.RESET.copy(),
            )
        }

        var *ii = &ids.get(tok.getRawIdentifier())
        // override/final are C++ keywords only in place, so not in clang's table.
        var contextual = lo.CPlusPlus != 0 && (text == "override" || text == "final")
        if ii->getTokenID() != clang::tok::identifier || contextual {
            return self.style(self.HL_KEYWORD.copy()) + text + self.style(
                self.RESET.copy(),
            )
        }

        var k = end
        while k < line.size() && (line.data()[k] == (' ' as u8) || line.data()[k] == ('\t' as u8)) {
            k += 1
        }

        if k < line.size() && line.data()[k] == ('(' as u8) {
            return self.style(self.HL_FUNC.copy()) + text + self.style(
                self.RESET.copy(),
            )
        }

        if self.is_upper(text.data()[0]) {
            return self.style(self.HL_TYPE.copy()) + text + self.style(
                self.RESET.copy(),
            )
        }

        return text
    }

    /// # Helpers

    fn split_lines(self, const text: string) -> cxx::std::vector<string> {
        var lines        = cxx::std::vector<string>()
        var start: usize = 0
        for i in (0 as usize) .. (text.size()) {
            if text.data()[i] == ('\n' as u8) {
                lines.push_back(text.subslice(start, i - start))
                start = i + 1
            }
        }

        if start <= text.size() {
            lines.push_back(text.subslice(start, text.size() - start))
        }

        return lines
    }

    fn highlight_snippet(self, const code: string) -> string {
        return self.highlight(code.copy(), "kairo")
    }

    pub fn highlight_snippet(self, const code: string, const lang: string) -> string {
        return self.highlight(code.copy(), lang)
    }

    fn heading_level(self, const line: string) -> u32 {
        var level: u32 = 0
        while level < 4
            && (level as usize) < line.size()
            && line.data()[level as usize] == ('#' as u8) {
            level += 1
        }

        if level > 0
            && (level as usize) < line.size()
            && line.data()[level as usize] == (' ' as u8) {
            return level
        }

        return 0
    }

    fn after_prefix(self, const s: string, skip: u32) -> string {
        var start = (skip as usize)
        if start >= s.size() {
            return ""
        }

        return s.subslice(start, s.size() - start)
    }

    fn numbered_prefix(self, const line: string) -> string {
        // matches: "1. ", "12. ", "123. "
        var i: usize = 0
        while i < line.size() && line.data()[i] >= ('0' as u8) && line.data()[i] <= ('9' as u8) {
            i += 1
        }

        if i > 0
            && i + 1 < line.size()
            && line.data()[i] == ('.' as u8)
            && line.data()[i + 1] == (' ' as u8) {
            return line.subslice(0, i + 2)
        }

        return ""
    }

    fn find_word_end(self, const s: string, from: usize) -> usize {
        var i = from
        while i < s.size()
            && s.data()[i] != (' ' as u8)
            && s.data()[i] != ('`' as u8)
            && s.data()[i] != ('\n' as u8) {
            i += 1
        }

        return i
    }

    priv fn parse_fence(self, const line: string) -> Self::CodeBlockInfo {
        var info = Self::CodeBlockInfo()
        var rest = trim(line.subslice(3, line.size() - 3))

        // split on spaces: ```kairo file=a.k
        var i: usize = 0

        // language
        while i < rest.size() && rest.data()[i] != (' ' as u8) {
            i += 1
        }

        info.lang = rest.subslice(0, i)

        // remaining key=value pairs
        while i < rest.size() {
            while i < rest.size() && rest.data()[i] == (' ' as u8) {
                i += 1
            }

            var kv_start = i
            while i < rest.size() && rest.data()[i] != (' ' as u8) {
                i += 1
            }

            var kv = rest.subslice(kv_start, i - kv_start)

            var eq = find(kv, "=", 0)
            if eq != usize::MAX && eq > 0 && eq + 1 < kv.size() {
                var key = kv.subslice(0, eq)
                var val = kv.subslice(eq + 1, kv.size() - eq - 1)
                if key == "file" {
                    info.file = val.copy()
                }
            }
        }

        return info
    }
}

// TODO(replace with kairo test blocks)
pub fn Test() -> i32 {
    var r      = TermRenderer(false, 60)
    var errors = 0

    var check = fn (what: string, ok: bool) -> i32 {
        if ok {
            return 0
        }

        io::println(f"FAIL: {what}")
        return 1
    }

    errors += check("h1", r.heading_level("# Foo") == 1)
    errors += check("h2", r.heading_level("## Foo") == 2)
    errors += check("no heading", r.heading_level("no heading") == 0)
    errors += check("no space after #", r.heading_level("#nospace") == 0)
    errors += check("numbered prefix 1", r.numbered_prefix("1. foo") == "1. ")
    errors += check(
        "numbered prefix 12",
        r.numbered_prefix("12. foo") == "12. ",
    )

    errors += check("no numbered prefix", r.numbered_prefix("no number") == "")

    var closed = r.render("use `foo` here\n")
    errors += check(
        "a closed span prints its content",
        find(closed, "use foo here", 0) != usize::MAX,
    )

    // A span the text wraps across two lines leaves one backtick on each
    // line; it prints as itself, with every character after it.
    var split = r.render(
        "and a static `op\ndelete` gives a class an allocator\n",
    )

    io::println(split)
    errors += check(
        "an unclosed backtick prints with the text after it",
        find(split, "and a static `op", 0) != usize::MAX,
    )

    errors += check(
        "a backtick that closes nothing on its line prints",
        find(split, "delete` gives", 0) != usize::MAX,
    )

    var last = r.render("a backtick ends this line `\n")
    errors += check(
        "a backtick at the end of a line prints",
        find(last, "line `", 0) != usize::MAX,
    )

    var wrapped = r.render(
        "this is a very long line that should definitely wrap when rendered at sixty columns wide\n",
    )

    var lines = r.split_lines(wrapped)
    for var i: usize = 0; i < lines.size(); ++i {
        errors += check(
            f"wrapped line {i} fits in 60 columns",
            r.display_width(lines[i]) <= 60,
        )
    }

    return errors
}
