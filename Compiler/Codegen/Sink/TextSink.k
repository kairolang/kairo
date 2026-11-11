/// --- The Kairo Project ---------------------- Codegen/Sink/TextSink.k --- ///
///
///   \brief EmitSink that writes bytes. The interop header (EmitCXXHeader)
///          and --print-cxx. Same emitter, same fragments as the token
///          stream; only the landing differs.
///
///   Formatting is minimal and deterministic: one space between tokens,
///   a newline after `;` `{` `}` and after a directive, brace-depth
///   indentation. It is a golden-file format, not a style.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/Basic/TokenKinds.h"

import Codegen::Sink::EmitSink::EmitSink
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Token::Token::Token
import Token::TokenCacheManager::TokenCacheManager
import Token::TokenText::TokenText

pub class TextSink derives EmitSink {
    pub var out: string = ""

    priv var _sm:            unsafe *SourceManager
    priv var _tcm:           unsafe *TokenCacheManager
    priv var _depth:         usize                     = 0
    priv var _at_line_start: bool                      = true
    priv var _glue_next:     bool                      = false ///< suppress the space before the next token
    priv var _pending_brk:   bool                      = false ///< a `}` was written; break unless `;` follows
    priv var _after_op_kw:   bool                      = false ///< the last token was `operator`: glue a punctuator to it

    /// Line mode (EmitCXXHeader::line_directives, kals only): each line is
    /// built in `_line` and written at its break, under a `#line` naming the
    /// Kairo file and line of its first located token, or, for a line with
    /// none (guards, includes, glue the emitter invents), under one naming
    /// \ref self_path at the line's own number. A directive is written only
    /// where the attribution changes, so a run of lines from consecutive
    /// Kairo lines carries one.
    pub var line_mode: bool   = false
    pub var self_path: string = ""
    priv var _line:      string = ""
    priv var _line_file: string = ""
    priv var _line_no:   usize  = 0
    priv var _phys:      usize  = 0  ///< lines written to `out`
    priv var _map_file:  string = "" ///< what the next line of `out` is attributed to
    priv var _map_line:  usize  = 0

    pub fn TextSink(self, sm: unsafe *SourceManager, tcm: unsafe *TokenCacheManager) {
        self._sm  = sm
        self._tcm = tcm
    }

    override fn create(self, t: Token) -> bool {
        self._flush_pending()
        self._note(t.range)
        self._word(*TokenText::resolve(t, self._tcm).get_text(), false)
        return true
    }

    override fn create_ident(self, at: SourceRange, const spelling: string) -> bool {
        self._flush_pending()
        self._note(at)
        self._word(spelling, false)
        // spell() lexes `operator` as a word, not through keyword().
        if spelling == "operator" {
            self._after_op_kw = true
        }

        return true
    }

    /// Spacing is a pure function of the punctuator kind, so a header's text
    /// is identical in every TU that emits the same decl: that is what the
    /// ODR diff compares. `}` defers its line break so `};` stays one line.
    override fn punct(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        var unsafe *p = clang::tok::getPunctuatorSpelling(k)
        if p == &null {
            self.ice_at(at, "TextSink::punct: kind has no punctuator spelling")
        }

        var s = string(unsafe ((p as unsafe *const u8) as *const u8))

        var tight_before = k == clang::tok::semi || k == clang::tok::comma || k == clang::tok::r_paren
                        || k == clang::tok::greater || k == clang::tok::coloncolon || k == clang::tok::l_paren
                        || k == clang::tok::less || k == clang::tok::l_square || k == clang::tok::r_square
                        || k == clang::tok::star || k == clang::tok::amp || k == clang::tok::ampamp
                        // `operator+`, not `operator +`: the symbol is part of
                        // the name. `operator double` keeps its space, since
                        // an identifier is not a punctuator.
                        || self._after_op_kw
        var tight_after = k == clang::tok::l_paren
            || k == clang::tok::coloncolon
            || k == clang::tok::less
            || k == clang::tok::l_square
            || k == clang::tok::tilde

        if k == clang::tok::r_brace {
            if self._depth > 0 {
                self._depth -= 1
            }

            self._flush_pending()
            self._note(at)
            self._word(s, false)
            self._pending_brk = true
            return true
        }

        if k == clang::tok::semi { // `};` stays on the line.
            self._pending_brk = false
        }

        if k != clang::tok::semi {
            self._flush_pending()
        }

        self._note(at)
        self._word(s, tight_before)
        if tight_after {
            self._glue_next = true
        }

        if k == clang::tok::semi {
            self.brk()
        }

        if k == clang::tok::l_brace {
            self._depth += 1
            self.brk()
        }

        return true
    }

    override fn keyword(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        var unsafe *kw = clang::tok::getKeywordSpelling(k)
        if kw == &null {
            self.ice_at(at, "TextSink::keyword: kind is not a keyword")
        }

        self._flush_pending()
        self._note(at)
        self._word(string(unsafe ((kw as unsafe *const u8) as *const u8)), false)
        if k == clang::tok::kw_operator {
            self._after_op_kw = true
        }

        return true
    }

    override fn literal(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        self._flush_pending()
        self._note(at)
        self._word(*TokenText::from_range(at, self._sm).get_text(), false)
        return true
    }

    override fn create_int(self, at: SourceRange, @inout cxx_v: string) -> bool {
        self._flush_pending()
        self._note(at)
        self._word(cxx_v, false)
        return true
    }

    override fn create_str(self, at: SourceRange, @inout cxx_v: string) -> bool {
        self._flush_pending()
        self._note(at)
        self._word(cxx_v, false)
        return true
    }

    override fn create_char(self, at: SourceRange, @inout cxx_v: string) -> bool {
        self._flush_pending()
        self._note(at)
        self._word(cxx_v, false)
        return true
    }

    /// Own line, always. The text is appended with _at_line_start still
    /// true, so without clearing it the trailing brk() is a no-op and the
    /// next directive runs onto this one (`#pragma once#include ...`).
    override fn directive(self, at: SourceRange, const text: string) -> bool {
        self._flush_pending()
        if !self._at_line_start {
            self.brk()
        }

        self._put(text)
        self._at_line_start = false
        self.brk()
        return true
    }

    override fn system_header(self, at: SourceRange, const name: string) -> bool {
        return self.directive(at, "#include <" + name + ">")
    }

    override fn brk(self) {
        if self._at_line_start {
            return
        }

        if self.line_mode {
            self._flush_line()
        } else {
            self.out += "\n"
        }

        self._at_line_start = true
    }

    priv fn _put(self, const s: string) {
        if self.line_mode {
            self._line += s
        } else {
            self.out += s
        }
    }

    /// The first located token of the line names the line (line mode).
    priv fn _note(self, at: SourceRange) {
        if (!self.line_mode) || (!self._line_file.empty()) || (!at.start.is_valid()) || (self._sm == &null) {
            return
        }

        // Offset 0 is where the emitter anchors what it invents for a whole
        // file (the lowering helpers, namespace braces): not a declaration.
        if self._sm->resolve(at.start).offset == 0 {
            return
        }

        var fl   = self._sm->get_line_col(at.start)
        var name = self._sm->get_filename(fl.file_id as u32)
        if (fl.line == 0) || (!name.ends_with(".k")) {
            return
        }

        self._line_file = name
        self._line_no   = fl.line
    }

    priv fn _flush_line(self) {
        var file = self._line_file
        var line = self._line_no
        if file.empty() {
            file = self.self_path
            line = self._phys + 1
            if (self._map_file != file) || (self._map_line != line) {
                line += 1 // the directive takes this physical line
            }
        }

        if (self._map_file != file) || (self._map_line != line) {
            self.out += f"#line {line} \""
            self.out += file
            self.out += "\"\n"
            self._phys += 1
        }

        self.out += self._line
        self.out += "\n"
        self._phys += 1
        self._map_file  = file
        self._map_line  = line + 1
        self._line      = ""
        self._line_file = ""
        self._line_no   = 0
    }

    priv fn _flush_pending(self) {
        if self._pending_brk {
            self._pending_brk = false
            self.brk()
        }
    }

    priv fn _word(self, s: string, tight: bool) {
        self._flush_pending()
        if self._at_line_start {
            for var i: usize = 0; i < self._depth; ++i {
                self._put("    ")
            }

            self._at_line_start = false
        } else if !(tight || self._glue_next) {
            self._put(" ")
        }

        self._glue_next   = false
        self._after_op_kw = false
        self._put(s)
    }
}
