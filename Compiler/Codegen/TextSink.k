/// --- The Kairo Project ------------------------ Codegen/TextSink.k ------ ///
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/Basic/TokenKinds.h";

import Location::SourceRange::*;
import Location::SourceManager::*;
import Token::Token::*;
import Token::TokenCacheManager::*;
import Token::TokenText::*;
import Codegen::EmitSink::*;

class TextSink derives EmitSink {
    pub var out: string = "";

    priv var _sm:    obs::<SourceManager>;
    priv var _tcm:   obs::<TokenCacheManager>;
    priv var _depth: usize = 0;
    priv var _at_line_start: bool = true;
    priv var _glue_next:   bool = false;   ///< suppress the space before the next token
    priv var _pending_brk: bool = false;   ///< a `}` was written; break unless `;` follows
    priv var _after_op_kw: bool = false;   ///< inside an `operator` symbol: glue the next punctuator

    fn TextSink(self, sm: *SourceManager, tcm: *TokenCacheManager) {
        self._sm  = sm;
        self._tcm = tcm;
    }

    override fn create(self, t: Token) -> bool {
        self._word(TokenText::resolve(t, self._tcm).get_text(), false);
        return true;
    }

    override fn create_ident(self, at: SourceRange, spelling: string) -> bool {
        self._word(spelling, false);
        // spell() lexes `operator` as a word, not through keyword().
        if spelling == "operator" { self._after_op_kw = true; }
        return true;
    }

    /// Spacing is a pure function of the punctuator kind, so a header's text
    /// is identical in every TU that emits the same decl: that is what the
    /// ODR diff compares. `}` defers its line break so `};` stays one line.
    override fn punct(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        var p = clang::tok::getPunctuatorSpelling(k);
        ICE_IF(p == &null, "TextSink::punct: kind has no punctuator spelling");
        var s = string(p);

        var tight_before = (k == clang::tok::semi) || (k == clang::tok::comma) || (k == clang::tok::r_paren)
                        || (k == clang::tok::greater) || (k == clang::tok::coloncolon) || (k == clang::tok::l_paren)
                        || (k == clang::tok::less) || (k == clang::tok::l_square) || (k == clang::tok::r_square)
                        || (k == clang::tok::star) || (k == clang::tok::amp) || (k == clang::tok::ampamp)
                        // `operator+`, not `operator +`: the symbol is part of
                        // the name. `operator double` keeps its space, since
                        // an identifier is not a punctuator.
                        || self._after_op_kw;
        // spell() hands `+=` over as `+` then `=`, so the glue has to outlast
        // one punctuator. It stops at `(` / `[`: that is either the parameter
        // list or `operator()` / `operator[]`, whose closers are tight anyway,
        // and carrying it further would glue a body's `{` to `()`.
        var op_symbol = self._after_op_kw && (k != clang::tok::l_paren) && (k != clang::tok::l_square);
        var tight_after  = (k == clang::tok::l_paren) || (k == clang::tok::coloncolon) || (k == clang::tok::less)
                        || (k == clang::tok::l_square) || (k == clang::tok::tilde);

        if k == clang::tok::r_brace {
            if self._depth > 0 { self._depth -= 1; }
            self._flush_pending();
            self._word(s, false);
            self._pending_brk = true;
            return true;
        }
        if k == clang::tok::semi { self._pending_brk = false; }   // `};` stays on the line.
        self._word(s, tight_before);
        if op_symbol { self._after_op_kw = true; }
        if tight_after { self._glue_next = true; }
        if k == clang::tok::semi { self.brk(); }
        if k == clang::tok::l_brace { self._depth += 1; self.brk(); }
        return true;
    }

    override fn keyword(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        var kw = clang::tok::getKeywordSpelling(k);
        ICE_IF(kw == &null, "TextSink::keyword: kind is not a keyword");
        self._word(string(kw), false);
        if k == clang::tok::kw_operator { self._after_op_kw = true; }
        return true;
    }

    override fn literal(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        self._word(TokenText::from_range(at, self._sm).get_text(), false);
        return true;
    }

    override fn create_int(self, at: SourceRange, cxx: ref!(nstring)) -> bool {
        self._word(std::nstring_to_string(cxx), false);
        return true;
    }

    override fn create_str(self, at: SourceRange, cxx: ref!(nstring)) -> bool {
        self._word(std::nstring_to_string(cxx), false);
        return true;
    }

    /// Own line, always. The text is appended with _at_line_start still
    /// true, so without clearing it the trailing brk() is a no-op and the
    /// next directive runs onto this one (`#pragma once#include ...`).
    override fn directive(self, at: SourceRange, text: string) -> bool {
        self._flush_pending();
        if !self._at_line_start { self.brk(); }
        self.out += text;
        self._at_line_start = false;
        self.brk();
        return true;
    }

    override fn brk(self) {
        if self._at_line_start { return; }
        self.out += "\n";
        self._at_line_start = true;
    }

    priv fn _flush_pending(self) {
        if self._pending_brk { self._pending_brk = false; self.brk(); }
    }

    priv fn _word(self, s: string, tight: bool) {
        self._flush_pending();
        if self._at_line_start {
            for var i: usize = 0; i < self._depth; ++i { self.out += "    "; }
            self._at_line_start = false;
        } else if !(tight || self._glue_next) {
            self.out += " ";
        }
        self._glue_next = false;
        self._after_op_kw = false;
        self.out += s;
    }
}