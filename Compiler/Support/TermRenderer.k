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

import Support::EvalHash::compute_hash
import Token::TokenKind::{
    TokenKind,
    is_valid_token_kind,
    token_kind_to_readable_string,
}

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

    priv fn clip_to_width(self, const s: string, max_cols: u32) -> string {
        var w: u32   = 0
        var i: usize = 0
        while i < s.length() {
            var b           = (s[i])
            var step: usize = 1
            var cols: u32   = 1
            if (b & 0x80) == 0x00 {
                step = 1
                cols = 1
            } else if (b & 0xE0) == 0xC0 {
                step = 2
                cols = 1
            } else if (b & 0xF0) == 0xE0 {
                step = 3
                cols = 1
            } else if (b & 0xF8) == 0xF0 {
                step = 4
                cols = 2
            }

            if w + cols > max_cols {
                break
            }

            w += cols
            i += step
        }

        return s.subslice(0, i)
    }

    priv fn visible_width(self, const s: string) -> u32 {
        var w: u32   = 0
        var i: usize = 0
        while i < s.length() {
            var b = (s[i])
            if b < 0x80 {
                w += 1
                i += 1
            } else if (b & 0xE0) == 0xC0 {
                w += 1
                i += 2
            } else if (b & 0xF0) == 0xE0 {
                w += 1
                i += 3 // most BMP glyphs are 1 column (->, │, ┌ etc.)
            } else if (b & 0xF8) == 0xF0 {
                w += 2
                i += 4 // assume emoji/CJK supplementary are 2 columns
            } else {
                w += 1
                i += 1 // garbage byte, don't loop forever
            }
        }

        return w
    }

    pub fn render(self, const text: string) -> string {
        var lines           = self.split_lines(text)
        var out             = string()
        var in_code_block   = false
        var code_block_info = Self::CodeBlockInfo()

        var i: usize = 0
        while i < lines.size() {
            var line    = lines[i]
            var trimmed = self.trim(line)

            /// ## fenced code block
            if self.starts_with(trimmed, "```") {
                if in_code_block {
                    // closing fence - draw bottom border
                    out += self.style(self.DIM)
                    out += "  └"
                    for _ in (0 as u32) .. self._width - 4 {
                        out += "-"
                    }

                    out += "┘"
                    out += self.style(self.RESET)
                    out += "\n"
                    in_code_block = false
                    i += 1
                    continue
                }

                // opening fence
                var info = self.parse_fence(trimmed)
                in_code_block   = true
                code_block_info = info

                // draw top border with lang/file
                out += self.style(self.DIM)
                out += "  ┌"

                var header = string()
                if info.lang.length() > 0 {
                    header += " " + info.lang + " "
                }

                if info.file.length() > 0 {
                    if header.length() > 0 {
                        header += "· "
                    } else {
                        header += " "
                    }

                    header += info.file + " "
                }

                if header.length() > 0 {
                    out += "-"
                    out += self.style(self.RESET + self.BOLD)
                    out += header
                    out += self.style(self.RESET + self.DIM)
                    var remaining = self._width - 3 - (header.length() as u32) - 2
                    for _ in (0 as u32) .. remaining {
                        out += "-"
                    }
                } else {
                    for _ in (0 as u32) .. self._width - 4 {
                        out += "-"
                    }
                }

                out += "┐"
                out += self.style(self.RESET)
                out += "\n"
                i += 1
                continue
            }

            if in_code_block {
                var inner   = self._width - 5                     // was: width - 4
                var clipped = self.clip_to_width(line, inner - 1) // was: clip to inner

                out += self.style(self.DIM)
                out += "  │ "
                out += self.style(self.RESET)
                out += self.highlight(clipped, code_block_info.lang)

                var used = self.visible_width(clipped)
                for _ in (0 as u32) .. inner - used {
                    out += " "
                }

                out += self.style(self.DIM)
                out += "│"
                out += self.style(self.RESET)
                out += "\n"
                i += 1
                continue
            }

            if trimmed.length() == 0 {
                out += "\n"
                i += 1
                continue
            }

            var heading_level = self.heading_level(trimmed)
            if heading_level > 0 {
                var heading_text = self.trim(
                    self.after_prefix(trimmed, heading_level),
                )

                match heading_level {
                    case 1 {
                        out += self.style(self.BOLD + self.UNDERLINE)
                        out += heading_text
                        out += self.style(self.RESET)
                    } case 2 {
                        out += self.style(self.BOLD)
                        out += heading_text
                        out += self.style(self.RESET)
                    } case 3 {
                        out += self.style(self.BOLD + self.DIM)
                        out += heading_text
                        out += self.style(self.RESET)
                    } default {
                        out += self.style(self.DIM)
                        out += heading_text
                        out += self.style(self.RESET)
                    }
                }

                out += "\n"
                i += 1
                continue
            }

            if self.starts_with(trimmed, "- ") {
                var content = trimmed.subslice(2, trimmed.length() - 2)
                out += self.wrap_inline(content, 4, "  • ")
                i += 1
                continue
            }

            var num_prefix = self.numbered_prefix(trimmed)
            if num_prefix.length() > 0 {
                var content = trimmed.subslice(
                    num_prefix.length(),
                    trimmed.length() - num_prefix.length(),
                )

                var pad = string()
                for _ in (0 as usize) .. ((num_prefix.length() + 2)) {
                    pad += " "
                }

                out += self.wrap_inline(
                    content,
                    pad.length() as u32,
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

    /// Terminal columns \p s occupies: UTF-8 is decoded, an East Asian
    /// Wide / Fullwidth codepoint is 2 columns, a combining mark, zero-width
    /// format character (ZWJ, ZWSP, BOM) or variation selector is 0, anything
    /// else 1. Each byte of invalid UTF-8 counts as 1, so a malformed line
    /// still advances. `length()` counted bytes, which put the caret and the
    /// wrap point past any non-ASCII text.
    priv fn display_width(self, const s: string) -> u32 {
        var w: u32   = 0
        var i: usize = 0
        var n        = s.length()
        while i < n {
            var b0         = ((s[i]) as u32)
            var len: usize = 0
            var cp:  u32   = 0
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
                var bk = ((s[i + k]) as u32)
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
                w += 1
                i += 1
                continue
            }

            if !self.is_zero_width(cp) {
                w += if self.is_wide(cp) => (2) else => 1
            }

            i += len
        }

        return w
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
        while i < text.length() {
            if text[i] == ('`' as u8) {
                var close = self.find_char(text, '`' as u8, i + 1)
                if close > i {
                    var code_text = text.subslice(i + 1, close - i - 1)
                    var styled = self.style(self.CYAN) + code_text + self.style(
                        self.RESET,
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

            if text[i] == (' ' as u8) {
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

            out.push_back(text[i])
            col += 1
            i += 1
        }

        out += "\n"
        return out
    }

    /// # Syntax highlighting

    priv fn is_digit(self, c: u8) -> bool {
        return c >= ('0' as u8) && c <= ('9' as u8)
    }

    priv fn is_alpha(self, c: u8) -> bool {
        return c >= ('a' as u8) && c <= ('z' as u8) || c >= ('A' as u8) && c <= ('Z' as u8)
    }

    priv fn is_upper(self, c: u8) -> bool {
        return c >= ('A' as u8) && c <= ('Z' as u8)
    }

    priv fn is_ident_start(self, c: u8) -> bool {
        return self.is_alpha(c) || c == ('_' as u8) || c == ('#' as u8)
    }

    priv fn is_ident_char(self, c: u8) -> bool {
        return self.is_alpha(c) || self.is_digit(c) || c == ('_' as u8) || c == ('#' as u8)
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
        var n         = line.length()

        while i < n {
            var c = line[i]

            // whitespace - emit raw, preserves indentation
            if c == (' ' as u8) || c == ('\t' as u8) {
                out.push_back(c)
                i += 1
                continue
            }

            // line comment
            if c == ('/' as u8) && i + 1 < n && line[i + 1] == ('/' as u8) {
                var rest = line.subslice(i, n - i)
                out += self.style(self.HL_COMMENT) + rest + self.style(
                    self.RESET,
                )

                i = n
                continue
            }

            // block comment (same-line only)
            if c == ('/' as u8) && i + 1 < n && line[i + 1] == ('*' as u8) {
                var j = i + 2
                while j + 1 < n && !(line[j] == ('*' as u8) && line[j + 1] == ('/' as u8)) {
                    j += 1
                }

                var end = if (j + 1 < n) => (j + 2) else => n
                var seg = line.subslice(i, end - i)
                out += self.style(self.HL_COMMENT) + seg + self.style(
                    self.RESET,
                )

                i = end
                continue
            }

            // raw string  r"..."
            if (c == ('r' as u8) || c == ('R' as u8))
                && i + 1 < n
                && line[i + 1] == ('\x22' as u8) {
                var j = i + 2
                while j < n && line[j] != ('\x22' as u8) {
                    j += 1
                }

                if j < n {
                    j += 1
                }

                var seg = line.subslice(i, j - i)
                out += self.style(self.HL_STRING) + seg + self.style(self.RESET)
                i = j
                continue
            }

            // string literal
            if c == ('\x22' as u8) {
                var j = i + 1
                while j < n && line[j] != ('\x22' as u8) {
                    if line[j] == ('\\' as u8) && j + 1 < n {
                        j += 1
                    }

                    j += 1
                }

                if j < n {
                    j += 1
                }

                var seg = line.subslice(i, j - i)
                out += self.style(self.HL_STRING) + seg + self.style(self.RESET)
                i = j
                continue
            }

            // char literal
            if c == ('\'' as u8) {
                var j = i + 1
                while j < n && line[j] != ('\'' as u8) {
                    if line[j] == ('\\' as u8) && j + 1 < n {
                        j += 1
                    }

                    j += 1
                }

                if j < n {
                    j += 1
                }

                var seg = line.subslice(i, j - i)
                out += self.style(self.HL_STRING) + seg + self.style(self.RESET)
                i = j
                continue
            }

            // number  (handles 0xFF, 0b1010, 1.5, 1e3 prefix)
            if self.is_digit(c) {
                var j = i
                while j < n && (self.is_ident_char(line[j]) || line[j] == ('.' as u8)) {
                    j += 1
                }

                var seg = line.subslice(i, j - i)
                out += self.style(self.HL_NUMBER) + seg + self.style(self.RESET)
                i = j
                continue
            }

            // attributes (e.g., @property)
            if c == ('@' as u8) {
                var j = i + 1
                while j < n && self.is_ident_char(line[j]) {
                    j += 1
                }

                var seg = line.subslice(i, j - i)
                out += self.style(self.HL_ATTRIBUTE) + seg + self.style(
                    self.RESET,
                )

                i = j
                continue
            }

            // identifier / keyword / type / call
            if self.is_ident_start(c) {
                var j = i
                while j < n && self.is_ident_char(line[j]) {
                    j += 1
                }

                var word = line.subslice(i, j - i)

                // peek next non-space for '(' -> function call
                var k = j
                while k < n && (line[k] == (' ' as u8) || line[k] == ('\t' as u8)) {
                    k += 1
                }

                var is_call = k < n && line[k] == ('(' as u8)

                var kind = self.word_kind(word)

                if self.is_value_word(kind) {
                    out += self.style(self.HL_NUMBER) + word + self.style(
                        self.RESET,
                    )
                } else if self.is_keyword(word, kind) {
                    out += self.style(self.HL_KEYWORD) + word + self.style(
                        self.RESET,
                    )
                } else if is_call {
                    out += self.style(self.HL_FUNC) + word + self.style(
                        self.RESET,
                    )
                } else if self.is_upper(c) {
                    out += self.style(self.HL_TYPE) + word + self.style(
                        self.RESET,
                    )
                } else {
                    out += word
                }

                i = j
                continue
            }


            // operators / punctuation - left neutral
            out.push_back(c)
            i += 1
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

        var n                      = line.length()
        var out                    = string()
        var pos:      usize        = 0             ///< bytes of `line` already in `out`
        var first                  = true
        var directive              = false         ///< the token after a line-leading `#`
        var held_at                = false         ///< an ObjC `@`, held to join what follows
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
                if gap.length() == 0 {
                    if kind == clang::tok::raw_identifier {
                        var *ai = &ids.get(tok.getRawIdentifier())
                        if ai->getObjCKeywordID() != clang::tok::objc_not_keyword {
                            out += self.style(self.HL_KEYWORD) + "@" + text + self.style(
                                self.RESET,
                            )

                            first = false
                            if last {
                                break
                            }

                            continue
                        }
                    } else if clang::tok::isLiteral(kind) {
                        var hl = if (kind == clang::tok::numeric_constant) => (self.HL_NUMBER)
                                 else => self.HL_STRING
                        out += self.style(hl) + "@" + text + self.style(
                            self.RESET,
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
                out += self.style(self.HL_COMMENT) + text + self.style(
                    self.RESET,
                )
            } else if kind == clang::tok::numeric_constant {
                out += self.style(self.HL_NUMBER) + text + self.style(
                    self.RESET,
                )
            } else if clang::tok::isLiteral(kind) {
                out += self.style(self.HL_STRING) + text + self.style(
                    self.RESET,
                )
            } else if kind == clang::tok::hash && first {
                out += self.style(self.HL_KEYWORD) + text + self.style(
                    self.RESET,
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
                    out += self.style(self.HL_KEYWORD) + text + self.style(
                        self.RESET,
                    )

                    // The raw lexer splits `<a/b.h>` into punctuation: the
                    // header name is the rest of the line.
                    if text == "include"
                        || text == "include_next"
                        || text == "import"
                        || text == "embed" {
                        var at = pos
                        while at < n && (line[at] == (' ' as u8) || line[at] == ('\t' as u8)) {
                            at += 1
                        }

                        out += line.subslice(pos, at - pos)
                        if at < n {
                            out += self.style(self.HL_STRING) + line.subslice(
                                at,
                                n - at,
                            ) + self.style(self.RESET)
                        }

                        pos = n
                        break
                    }
                } else {
                    out += self.clang_word(&ids, &lo, &tok, text, line, end)
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
            return self.style(self.HL_NUMBER) + text + self.style(self.RESET)
        }

        var *ii = &ids.get(tok.getRawIdentifier())
        // override/final are C++ keywords only in place, so not in clang's table.
        var contextual = lo.CPlusPlus != 0 && (text == "override" || text == "final")
        if ii->getTokenID() != clang::tok::identifier || contextual {
            return self.style(self.HL_KEYWORD) + text + self.style(self.RESET)
        }

        var k = end
        while k < line.length() && (line[k] == (' ' as u8) || line[k] == ('\t' as u8)) {
            k += 1
        }

        if k < line.length() && line[k] == ('(' as u8) {
            return self.style(self.HL_FUNC) + text + self.style(self.RESET)
        }

        if self.is_upper(text[0]) {
            return self.style(self.HL_TYPE) + text + self.style(self.RESET)
        }

        return text
    }

    /// # Helpers

    fn split_lines(self, const text: string) -> cxx::std::vector<string> {
        var lines        = cxx::std::vector<string>()
        var start: usize = 0
        for i in (0 as usize) .. (text.length()) {
            if text[i] == ('\n' as u8) {
                lines.push_back(text.subslice(start, i - start))
                start = i + 1
            }
        }

        if start <= text.length() {
            lines.push_back(text.subslice(start, text.length() - start))
        }

        return lines
    }

    fn highlight_snippet(self, const code: string) -> string {
        return self.highlight(code, "kairo")
    }

    pub fn highlight_snippet(self, const code: string, const lang: string) -> string {
        return self.highlight(code, lang)
    }

    fn trim(self, const s: string) -> string {
        var start: usize = 0
        var end:   usize = s.length()
        while start < end && (s[start] == (' ' as u8) || s[start] == ('\t' as u8)) {
            start += 1
        }

        while end > start && (s[end - 1] == (' ' as u8) || s[end - 1] == ('\t' as u8)) {
            end -= 1
        }

        return s.subslice(start, end - start)
    }

    fn starts_with(self, const s: string, const prefix: string) -> bool {
        if s.length() < prefix.length() {
            return false
        }

        for i in (0 as usize) .. (prefix.length()) {
            if s[i] != prefix[i] {
                return false
            }
        }

        return true
    }

    fn heading_level(self, const line: string) -> u32 {
        var level: u32 = 0
        while level < 4 && (level as usize) < line.length() && line[level as usize] == ('#' as u8) {
            level += 1
        }

        if level > 0 && (level as usize) < line.length() && line[level as usize] == (' ' as u8) {
            return level
        }

        return 0
    }

    fn after_prefix(self, const s: string, skip: u32) -> string {
        var start = (skip as usize)
        if start >= s.length() {
            return ""
        }

        return s.subslice(start, s.length() - start)
    }

    fn numbered_prefix(self, const line: string) -> string {
        // matches: "1. ", "12. ", "123. "
        var i: usize = 0
        while i < line.length() && line[i] >= ('0' as u8) && line[i] <= ('9' as u8) {
            i += 1
        }

        if i > 0 && i + 1 < line.length() && line[i] == ('.' as u8) && line[i + 1] == (' ' as u8) {
            return line.subslice(0, i + 2)
        }

        return ""
    }

    fn find_char(self, const s: string, ch: u8, from: usize) -> usize {
        for i in (from) .. (s.length()) {
            if s[i] == ch {
                return i
            }
        }

        return from // not found, return start so caller knows
    }

    fn find_word_end(self, const s: string, from: usize) -> usize {
        var i = from
        while i < s.length() && s[i] != (' ' as u8) && s[i] != ('`' as u8) && s[i] != ('\n' as u8) {
            i += 1
        }

        return i
    }

    priv fn parse_fence(self, const line: string) -> Self::CodeBlockInfo {
        var info = Self::CodeBlockInfo()
        var rest = self.trim(line.subslice(3, line.length() - 3))

        // split on spaces: ```kairo file=a.k
        var i: usize = 0

        // language
        while i < rest.length() && rest[i] != (' ' as u8) {
            i += 1
        }

        info.lang = rest.subslice(0, i)

        // remaining key=value pairs
        while i < rest.length() {
            while i < rest.length() && rest[i] == (' ' as u8) {
                i += 1
            }

            var kv_start = i
            while i < rest.length() && rest[i] != (' ' as u8) {
                i += 1
            }

            var kv = rest.subslice(kv_start, i - kv_start)

            var eq = self.find_char(kv, '=' as u8, 0)
            if eq > 0 && eq < kv.length() - 1 {
                var key = kv.subslice(0, eq)
                var val = kv.subslice(eq + 1, kv.length() - eq - 1)
                if key == "file" {
                    info.file = val
                }
            }
        }

        return info
    }
}

// fn Test() -> i32 {
//     var r = TermRenderer(true, 60);

//     var input = string(
//         "# Return Type Mismatch\n"
//         "\n"
//         "The function's declared return type does not match\n"
//         "the expression in the `return` statement.\n"
//         "\n"
//         "## Common causes\n"
//         "\n"
//         "1. The function signature says `void` but the body returns a value\n"
//         "2. The return expression type doesn't match\n"
//         "3. An implicit conversion is not available\n"
//         "\n"
//         "## Example\n"
//         "\n"
//         "```kairo\n"
//         "fn foo() -> void {\n"
//         "    return 42;  // error\n"
//         "}\n"
//         "```\n"
//         "\n"
//         "## Fixes\n"
//         "\n"
//         "- Change the return type to match the expression\n"
//         "- Remove the expression from the `return` statement\n"
//         "- Add an explicit cast\n"
//     );

//     var output = r.render(input);
//     std::print(output);

//     // --- individual checks ---
//     var errors: i32 = 0;

//     // heading detection
//     if r.heading_level("# Foo") != 1   { std::print("FAIL: h1\n"); errors += 1; }
//     if r.heading_level("## Foo") != 2  { std::print("FAIL: h2\n"); errors += 1; }
//     if r.heading_level("### Foo") != 3 { std::print("FAIL: h3\n"); errors += 1; }
//     if r.heading_level("no heading") != 0 { std::print("FAIL: no heading\n"); errors += 1; }
//     if r.heading_level("#nospace") != 0   { std::print("FAIL: no space after #\n"); errors += 1; }

//     // trim
//     if r.trim("  hello  ") != "hello"  { std::print("FAIL: trim\n"); errors += 1; }
//     if r.trim("") != ""               { std::print("FAIL: trim empty\n"); errors += 1; }

//     // starts_with
//     if !r.starts_with("- foo", "- ")   { std::print("FAIL: starts_with bullet\n"); errors += 1; }
//     if r.starts_with("foo", "- ")      { std::print("FAIL: starts_with negative\n"); errors += 1; }

//     // numbered prefix
//     if r.numbered_prefix("1. foo") != "1. "    { std::print("FAIL: num prefix 1\n"); errors += 1; }
//     if r.numbered_prefix("12. foo") != "12. "  { std::print("FAIL: num prefix 12\n"); errors += 1; }
//     if r.numbered_prefix("no number") != ""    { std::print("FAIL: num prefix none\n"); errors += 1; }

//     // code block toggle
//     var code_output = r.render(code_input);
//         std::print("FAIL: code block content missing\n");
//         errors += 1;
//     }

//     // inline code
//     var inline_input = string("use `foo` here\n");
//     var inline_output = r.render(inline_input);
//     if inline_output.raw_string().find("foo") == string::npos {
//         std::print("FAIL: inline code content missing\n");
//         errors += 1;
//     }

//     // word wrap -- check visible width, stripping ANSI
//     var long_line = string("this is a very long line that should definitely wrap when rendered at sixty columns wide\n");
//     var wrapped = r.render(long_line);
//     var wrap_lines = r.split_lines(wrapped);
//     for line in wrap_lines {
//         if line.length() > 62 {  // small margin for ansi codes
//             std::print(f"FAIL: line too long: {line.length()} chars\n");
//             errors += 1;
//         }
//     }

//     if errors == 0 {
//         std::print("\nAll tests passed.\n");
//     } else {
//         std::print(f"\n{errors} test(s) failed.\n");
//     }

//     return errors;
// }
