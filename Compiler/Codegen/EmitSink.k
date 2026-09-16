/// --- The Kairo Project ---------------------------- Codegen/EmitSink.k --- ///
///
///   \brief The surface every emitter writes through. Two sinks derive it:
///          TokenSink (located clang tokens, the per-TU preamble + bodies)
///          and TextSink (bytes, the interop header and --print-cxx).
///
///   \par Why a base class and not two emitters
///     The interface emitter produces the SAME declaration text for a
///     TU's preamble and for the module's C++ header (IMPORTS.md §6.6,
///     invariant 12). Two emitters would be two spellers, and two spellers
///     drift into a silent link error. One emitter, one string per
///     declaration, two ways to land it.
///
///   \par spell()
///     A declaration is built as C++ text and handed to spell() with the
///     Kairo range it stands for. spell() tokenizes: identifiers (and
///     every C++ keyword -- TokenSink resolves the kind through
///     IdentifierInfo, TextSink does not care), punctuators, integer
///     literals. It never sees a Kairo keyword token and never sees a
///     string literal; those still go through the typed accumulators.
///
///   Import law: this file and the two sinks may import clang. Emitters
///   see clang::tok transitively and import nothing.
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
import Token::Token::*;

class EmitSink {
    // --- Primitives: every sink implements these ------------------------------

    /// Kind AND spelling from a Kairo token (identifiers, punctuators).
    virtual fn create(self, t: Token) -> bool { ICE_FAIL("EmitSink::create: abstract"); return false; }

    /// An identifier whose spelling comes from elsewhere (a foreign TU's imm
    /// table, a builtin's C++ name). TokenSink interns it; a C++ keyword
    /// spelling resolves to its keyword kind through the IdentifierInfo.
    virtual fn create_ident(self, at: SourceRange, spelling: string) -> bool { ICE_FAIL("EmitSink::create_ident: abstract"); return false; }

    virtual fn punct(self, at: SourceRange, k: clang::tok::TokenKind) -> bool { ICE_FAIL("EmitSink::punct: abstract"); return false; }
    virtual fn keyword(self, at: SourceRange, k: clang::tok::TokenKind) -> bool { ICE_FAIL("EmitSink::keyword: abstract"); return false; }

    /// A BORROWED literal: the range's bytes ARE the spelling.
    virtual fn literal(self, at: SourceRange, k: clang::tok::TokenKind) -> bool { ICE_FAIL("EmitSink::literal: abstract"); return false; }

    /// DIVERGENT literals: the C++ spelling differs from the Kairo bytes.
    virtual fn create_int(self, at: SourceRange, cxx: ref!(nstring)) -> bool { ICE_FAIL("EmitSink::create_int: abstract"); return false; }
    virtual fn create_str(self, at: SourceRange, cxx: ref!(nstring)) -> bool { ICE_FAIL("EmitSink::create_str: abstract"); return false; }

    /// A preprocessor line (`#pragma once`, `#include "..."`). Text sinks
    /// only; a token stream has no line to put it on.
    virtual fn directive(self, at: SourceRange, text: string) -> bool { ICE_FAIL("EmitSink::directive: this sink is a token stream and cannot carry a preprocessor line"); return false; }

    /// Layout hint. TextSink breaks the line; TokenSink ignores it.
    virtual fn brk(self) { }

    // --- Sugar (non-virtual) -------------------------------------------------

    /// Kind supplied, span borrowed. Literal kinds borrow their bytes;
    /// keyword kinds go through keyword(); everything else is a punctuator.
    fn synth(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        if clang::tok::isLiteral(k) { return self.literal(at, k); }
        var kws = clang::tok::getKeywordSpelling(k);
        if kws != &null { return self.keyword(at, k); }
        return self.punct(at, k);
    }

    fn synth(self, t: Token, k: clang::tok::TokenKind) -> bool { return self.synth(t.range, k); }

    fn synth_at_start(self, r: SourceRange, k: clang::tok::TokenKind) -> bool {
        return self.synth(SourceRange::from_bounds(r.start, u32(1)), k);
    }

    fn synth_at_end(self, r: SourceRange, k: clang::tok::TokenKind) -> bool {
        var n = r.size();
        var last = r.start;
        if n > 1 { last = last.advance(static_cast::<usize>(n - 1)); }
        return self.synth(SourceRange::from_bounds(last, u32(1)), k);
    }

    fn create_int(self, t: Token, cxx: ref!(nstring)) -> bool { return self.create_int(t.range, cxx); }
    fn create_str(self, t: Token, cxx: ref!(nstring)) -> bool { return self.create_str(t.range, cxx); }

    fn kw_auto(self, t: Token) -> bool      { return self.synth(t, clang::tok::kw_auto);      }
    fn kw_return(self, t: Token) -> bool    { return self.synth(t, clang::tok::kw_return);    }
    fn kw_const(self, t: Token) -> bool     { return self.synth(t, clang::tok::kw_const);     }
    fn kw_static(self, t: Token) -> bool    { return self.synth(t, clang::tok::kw_static);    }
    fn kw_constexpr(self, t: Token) -> bool { return self.synth(t, clang::tok::kw_constexpr); }
    fn kw_if(self, t: Token) -> bool        { return self.synth(t, clang::tok::kw_if);        }
    fn kw_else(self, t: Token) -> bool      { return self.synth(t, clang::tok::kw_else);      }
    fn kw_while(self, t: Token) -> bool     { return self.synth(t, clang::tok::kw_while);     }
    fn kw_for(self, t: Token) -> bool       { return self.synth(t, clang::tok::kw_for);       }
    fn kw_break(self, t: Token) -> bool     { return self.synth(t, clang::tok::kw_break);     }
    fn kw_continue(self, t: Token) -> bool  { return self.synth(t, clang::tok::kw_continue);  }
    fn kw_switch(self, t: Token) -> bool    { return self.synth(t, clang::tok::kw_switch);    }
    fn kw_case(self, t: Token) -> bool      { return self.synth(t, clang::tok::kw_case);      }
    fn kw_default(self, t: Token) -> bool   { return self.synth(t, clang::tok::kw_default);   }

    // --- spell(): C++ text -> tokens -------------------------------------------

    /// Tokenize \p text and emit every token anchored at \p at. Accepts
    /// identifiers/keywords, integer literals, and the punctuators a
    /// declaration can contain. Anything else is an emitter bug.
    ///
    /// `<<` and `>>` are two tokens each EXCEPT directly after the word
    /// `operator`, so `Box<Box<int>>` and `operator<<` both come out right.
    fn spell(self, at: SourceRange, text: string) -> bool {
        var n = text.size();
        var i: usize = 0;
        var after_operator = false;
        var any = false;
        while i < n {
            var c = text[i];

            if (c == ' ') || (c == '\t') || (c == '\n') { i += 1; continue; }

            if self._is_ident_start(c) {
                var j = i + 1;
                while (j < n) && self._is_ident_char(text[j]) { j += 1; }
                var word = string(text.raw_string().substr(i, j - i));
                self.create_ident(at, word);
                after_operator = (word == "operator");
                any = true;
                i = j;
                continue;
            }

            if self._is_digit(c) {
                var j = i + 1;
                while (j < n) && (self._is_ident_char(text[j]) || (text[j] == '.')) { j += 1; }
                var lit = std::string_to_nstring(string(text.raw_string().substr(i, j - i)));
                self.create_int(at, lit);
                after_operator = false;
                any = true;
                i = j;
                continue;
            }

            var k = clang::tok::unknown;
            var len: usize = 1;
            var c1 = ' ';
            var c2 = ' ';
            if i + 1 < n { c1 = text[i + 1]; }
            if i + 2 < n { c2 = text[i + 2]; }

            if (c == ':') && (c1 == ':')                { k = clang::tok::coloncolon; len = 2; }
            else if (c == '-') && (c1 == '>')           { k = clang::tok::arrow;      len = 2; }
            else if (c == '.') && (c1 == '.') && (c2 == '.') { k = clang::tok::ellipsis; len = 3; }
            else if (c == '&') && (c1 == '&')           { k = clang::tok::ampamp;     len = 2; }
            else if (c == '<') && (c1 == '=') && (c2 == '>') { k = clang::tok::spaceship; len = 3; }
            else if (c == '<') && (c1 == '<') && after_operator { k = clang::tok::lessless; len = 2; }
            else if (c == '>') && (c1 == '>') && after_operator { k = clang::tok::greatergreater; len = 2; }
            else if (c == '=') && (c1 == '=')           { k = clang::tok::equalequal;   len = 2; }
            else if (c == '!') && (c1 == '=')           { k = clang::tok::exclaimequal; len = 2; }
            else if (c == '<') && (c1 == '=')           { k = clang::tok::lessequal;    len = 2; }
            else if (c == '>') && (c1 == '=')           { k = clang::tok::greaterequal; len = 2; }
            else if (c == '+') && (c1 == '+')           { k = clang::tok::plusplus;     len = 2; }
            else if (c == '-') && (c1 == '-')           { k = clang::tok::minusminus;   len = 2; }
            else if (c == '|') && (c1 == '|')           { k = clang::tok::pipepipe;     len = 2; }
            else { k = self._punct_kind(c); }

            ICE_IF(k == clang::tok::unknown,
                f"EmitSink::spell: unexpected character in C++ fragment: {text}");
            self.punct(at, k);
            after_operator = false;
            any = true;
            i += len;
        }
        return any;
    }

    priv fn _punct_kind(self, c: char) -> clang::tok::TokenKind {
        if c == '{' { return clang::tok::l_brace;  }
        if c == '}' { return clang::tok::r_brace;  }
        if c == '(' { return clang::tok::l_paren;  }
        if c == ')' { return clang::tok::r_paren;  }
        if c == '[' { return clang::tok::l_square; }
        if c == ']' { return clang::tok::r_square; }
        if c == ';' { return clang::tok::semi;     }
        if c == ',' { return clang::tok::comma;    }
        if c == ':' { return clang::tok::colon;    }
        if c == '<' { return clang::tok::less;     }
        if c == '>' { return clang::tok::greater;  }
        if c == '*' { return clang::tok::star;     }
        if c == '&' { return clang::tok::amp;      }
        if c == '=' { return clang::tok::equal;    }
        if c == '~' { return clang::tok::tilde;    }
        if c == '!' { return clang::tok::exclaim;  }
        if c == '+' { return clang::tok::plus;     }
        if c == '-' { return clang::tok::minus;    }
        if c == '/' { return clang::tok::slash;    }
        if c == '%' { return clang::tok::percent;  }
        if c == '^' { return clang::tok::caret;    }
        if c == '|' { return clang::tok::pipe;     }
        if c == '.' { return clang::tok::period;   }
        if c == '?' { return clang::tok::question; }
        return clang::tok::unknown;
    }

    priv fn _is_ident_start(self, c: char) -> bool {
        return ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || (c == '_');
    }
    priv fn _is_digit(self, c: char) -> bool { return (c >= '0') && (c <= '9'); }
    priv fn _is_ident_char(self, c: char) -> bool { return self._is_ident_start(c) || self._is_digit(c); }
}
