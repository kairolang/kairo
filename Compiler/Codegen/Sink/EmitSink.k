/// --- The Kairo Project ---------------------- Codegen/Sink/EmitSink.k --- ///
///
///   \brief The surface every emitter writes through. Two sinks derive it:
///          TokenSink (located clang tokens, the per-TU preamble + bodies)
///          and TextSink (bytes, the interop header and --print-cxx).
///
///   \par Why a base class and not two emitters
///     The interface emitter produces the SAME declaration text for a
///     TU's preamble and for the module's C++ header (Compiler/Spec/Codegen.md#plan-modes,
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/Basic/TokenKinds.h"

import AST::Context::ASTContext::ASTContext
import Codegen::CodegenICE::codegen_ice
import Location::SourceRange::SourceRange
import Token::Token::Token

pub class EmitSink {
    @move
    fn EmitSink(self, other: Self) = default
    fn EmitSink(self) = default
    virtual fn op finally(self) { }
    /// The context an ICE reports through (CodegenICE). Bound by the
    /// CodegenContext that adopts the sink; null before that, which only
    /// costs the ICE its source location.
    pub var ice_ctx: unsafe *ASTContext = &null

    /// ICE naming the Kairo source at \p at (CodegenICE).
    fn ice_at(self, at: SourceRange, const msg: string) {
        codegen_ice(self.ice_ctx, at, msg)
    }

    /// # Primitives: every sink implements these

    /// Kind AND spelling from a Kairo token (identifiers, punctuators).
    virtual fn create(self, t: Token) -> bool {
        self.ice_at(t.range, "EmitSink::create: abstract")
        return false
    }

    /// An identifier whose spelling comes from elsewhere (a foreign TU's imm
    /// table, a builtin's C++ name). TokenSink interns it; a C++ keyword
    /// spelling resolves to its keyword kind through the IdentifierInfo.
    virtual fn create_ident(self, at: SourceRange, const spelling: string) -> bool {
        self.ice_at(at, "EmitSink::create_ident: abstract")
        return false
    }

    virtual fn punct(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        self.ice_at(at, "EmitSink::punct: abstract")
        return false
    }

    virtual fn keyword(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        self.ice_at(at, "EmitSink::keyword: abstract")
        return false
    }

    /// A BORROWED literal: the range's bytes ARE the spelling.
    virtual fn literal(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        self.ice_at(at, "EmitSink::literal: abstract")
        return false
    }

    /// DIVERGENT literals: the C++ spelling differs from the Kairo bytes.
    virtual fn create_int(self, at: SourceRange, @inout cxx_v: string) -> bool {
        self.ice_at(at, "EmitSink::create_int: abstract")
        return false
    }

    virtual fn create_str(self, at: SourceRange, @inout cxx_v: string) -> bool {
        self.ice_at(at, "EmitSink::create_str: abstract")
        return false
    }

    virtual fn create_char(self, at: SourceRange, @inout cxx_v: string) -> bool {
        self.ice_at(at, "EmitSink::create_char: abstract")
        return false
    }

    /// A preprocessor line (`#pragma once`, `#include "..."`). Text sinks
    /// only; a token stream has no line to put it on.
    virtual fn directive(self, at: SourceRange, const text: string) -> bool {
        self.ice_at(
            at,
            "EmitSink::directive: this sink is a token stream and cannot carry a preprocessor line",
        )

        return false
    }

    /// `#include <name>`: a system header the emitted C++ needs (<new>, for
    /// a derived `op =` that rebuilds in place). TextSink writes the line;
    /// TokenSink records it, and KairoInject enters it ahead of the stream.
    virtual fn system_header(self, at: SourceRange, const name: string) -> bool {
        self.ice_at(at, "EmitSink::system_header: abstract")
        return false
    }

    /// Layout hint. TextSink breaks the line; TokenSink ignores it.
    virtual fn brk(self) { }

    /// Tokens until the next unanchored(false) have no Kairo bytes of their
    /// own (the lowering helpers): TokenSink gives them arena locations, so
    /// they take none of the file's bytes from the tokens that do. TextSink
    /// has no locations.
    virtual fn unanchored(self, on: bool) { }
    /// Whether unanchored(true) is in force: spell() leaves an emitter's
    /// own unanchored span alone rather than ending it after an attribute.
    virtual fn is_unanchored(self) -> bool {
        return false
    }

    /// # Sugar (non-virtual)

    /// Kind supplied, span borrowed. Literal kinds borrow their bytes;
    /// keyword kinds go through keyword(); everything else is a punctuator.
    fn synth(self, at: SourceRange, k: clang::tok::TokenKind) -> bool {
        if clang::tok::isLiteral(k) {
            return self.literal(at, k)
        }

        var unsafe *kws = clang::tok::getKeywordSpelling(k)
        if kws != &null {
            return self.keyword(at, k)
        }

        return self.punct(at, k)
    }

    fn synth(self, t: Token, k: clang::tok::TokenKind) -> bool {
        return self.synth(t.range, k)
    }

    fn synth_at_start(self, r: SourceRange, k: clang::tok::TokenKind) -> bool {
        return self.synth(SourceRange::from_bounds(r.start, 1 as u32), k)
    }

    fn synth_at_end(self, r: SourceRange, k: clang::tok::TokenKind) -> bool {
        var n    = r.size()
        var last = r.start
        if n > 1 {
            last = last.advance((n - 1) as usize)
        }

        return self.synth(SourceRange::from_bounds(last, 1 as u32), k)
    }

    fn create_int(self, t: Token, @inout cxx_v: string) -> bool {
        return self.create_int(t.range, &cxx_v)
    }

    fn create_str(self, t: Token, @inout cxx_v: string) -> bool {
        return self.create_str(t.range, &cxx_v)
    }

    fn kw_auto(self, t: Token) -> bool {
        return self.synth(t, clang::tok::kw_auto)
    }

    fn kw_return(self, t: Token) -> bool {
        return self.synth(t, clang::tok::kw_return)
    }

    fn kw_const(self, t: Token) -> bool {
        return self.synth(t, clang::tok::kw_const)
    }

    fn kw_static(self, t: Token) -> bool {
        return self.synth(t, clang::tok::kw_static)
    }

    fn kw_thread_local(self, t: Token) -> bool {
        return self.synth(t, clang::tok::kw_thread_local)
    }

    fn kw_constexpr(self, t: Token) -> bool {
        return self.synth(t, clang::tok::kw_constexpr)
    }

    fn kw_if(self, t: Token) -> bool {
        return self.synth(t, clang::tok::kw_if)
    }

    fn kw_else(self, t: Token) -> bool {
        return self.synth(t, clang::tok::kw_else)
    }

    fn kw_while(self, t: Token) -> bool {
        return self.synth(t, clang::tok::kw_while)
    }

    fn kw_for(self, t: Token) -> bool {
        return self.synth(t, clang::tok::kw_for)
    }

    fn kw_break(self, t: Token) -> bool {
        return self.synth(t, clang::tok::kw_break)
    }

    fn kw_continue(self, t: Token) -> bool {
        return self.synth(t, clang::tok::kw_continue)
    }

    fn kw_switch(self, t: Token) -> bool {
        return self.synth(t, clang::tok::kw_switch)
    }

    fn kw_case(self, t: Token) -> bool {
        return self.synth(t, clang::tok::kw_case)
    }

    fn kw_default(self, t: Token) -> bool {
        return self.synth(t, clang::tok::kw_default)
    }

    /// # spell(): C++ text -> tokens

    /// Tokenize \p text and emit every token anchored at \p at. Accepts
    /// identifiers/keywords, integer and string literals, and the punctuators a
    /// declaration can contain. Anything else is an emitter bug.
    ///
    /// Punctuators are matched longest-first. `<<`, `>>`, `<<=` and `>>=`
    /// are one token only directly after the word `operator`, so
    /// `Box<Box<int>>` and `operator<<` both come out right.
    ///
    /// An attribute (`__attribute__((...))`, `[[...]]`) is spelled
    /// unanchored: it has no Kairo bytes of its own, and on the declaration's
    /// anchor its tokens took the bytes ahead of the ones that do.
    /// Every token of a declaration claims the next free byte from one
    /// anchor, so the six of an inferred `__attribute__((const))` pushed each
    /// parameter six columns on, and clang's "passing argument to parameter
    /// 'a' here" landed on `b`'s type. Unanchored, they go to the arena and
    /// the real tokens keep the bytes they have without the attribute.
    fn spell(self, at: SourceRange, const text: string) -> bool {
        var n                    = text.size()
        var i:             usize = 0
        var after_operator       = false
        var any                  = false
        // The attribute this spell() made unanchored: the kind that opens
        // and closes it, and how deep in it the stream is. Its own brackets
        // end it, so `[[nodiscard]] int f(...)` goes back to the anchor at
        // `int`.
        var attr_open         = false
        var attr_l            = clang::tok::l_paren
        var attr_r            = clang::tok::r_paren
        var attr_depth: usize = 0
        while i < n {
            var c = text[i]

            if c == (' ' as u8) || c == ('\t' as u8) || c == ('\n' as u8) {
                i += 1
                continue
            }

            // An emitter's own unanchored span is left alone: ending it here
            // would anchor the rest of it.
            if !attr_open && !self.is_unanchored() {
                var gnu = self._is_ident_start(c) && self._attr_word_at(text, i)
                var square = c == ('[' as u8) && i + 1 < n && text[i + 1] == ('[' as u8)
                if gnu || square {
                    self.unanchored(true)
                    attr_open  = true
                    attr_depth = 0
                    attr_l     = (if (square) => (clang::tok::l_square) else => clang::tok::l_paren)
                    attr_r     = (if (square) => (clang::tok::r_square) else => clang::tok::r_paren)
                }
            }

            if self._is_ident_start(c) {
                var j = i + 1
                while j < n && self._is_ident_char(text[j]) {
                    j += 1
                }

                var word = text.subslice(i, j - i)
                self.create_ident(at, word)
                after_operator = word == "operator"
                any            = true
                i              = j
                continue
            }

            if self._is_digit(c) {
                var j = i + 1
                // A float's exponent sign is the literal's own: `0x1p-126f`,
                // `1e+5`. Hex reads only `p`, since its `e` is a digit.
                var hex = j < n
                    && (text[j] == ('x' as u8) || text[j] == ('X' as u8))
                    && c == ('0' as u8)
                while j < n {
                    var cj = text[j]
                    if self._is_ident_char(cj) || cj == ('.' as u8) {
                        j += 1
                        continue
                    }

                    if (cj == ('+' as u8) || cj == ('-' as u8))
                        && j + 1 < n
                        && self._is_digit(text[j + 1]) {
                        var pc = text[j - 1]
                        var expo = pc == ('p' as u8)
                            || pc == ('P' as u8)
                            || !hex && (pc == ('e' as u8) || pc == ('E' as u8))
                        if expo {
                            j += 1
                            continue
                        }
                    }

                    break
                }

                var lit = text.subslice(i, j - i)
                self.create_int(at, &lit)
                after_operator = false
                any            = true
                i              = j
                continue
            }

            // A string literal, quotes and escapes kept verbatim: the
            // language-linkage `extern "C"` is the one a declaration needs.
            if c == ('\x22' as u8) {
                var j = i + 1
                while j < n && text[j] != ('\x22' as u8) {
                    if text[j] == ('\\' as u8) {
                        j += 1
                    }

                    j += 1
                }

                if j >= n {
                    self.ice_at(
                        at,
                        f"EmitSink::spell: unterminated string literal in C++ fragment: {text}",
                    )
                }

                // `operator""_len`: the suffix is part of the literal token,
                // as the C++ lexer reads it. Split into `""` and `_len` the
                // tokens were C++23's deprecated `operator "" _len`, and
                // clang warned C271W at every literal-operator call.
                var end = j + 1
                if after_operator && end < n && self._is_ident_start(text[end]) {
                    while end < n && self._is_ident_char(text[end]) {
                        end += 1
                    }
                }

                var lit = text.subslice(i, end - i)
                self.create_str(at, &lit)
                after_operator = false
                any            = true
                i              = end
                continue
            }

            // A character literal, quotes and escapes kept verbatim: clang
            // prints a `char` / `unsigned char` template argument as one, so
            // an imported instance's spelling can hold it (`Narrow<'\xff'>`).
            if c == ('\x27' as u8) {
                var j = i + 1
                while j < n && text[j] != ('\x27' as u8) {
                    if text[j] == ('\\' as u8) {
                        j += 1
                    }

                    j += 1
                }

                if j >= n {
                    self.ice_at(
                        at,
                        f"EmitSink::spell: unterminated character literal in C++ fragment: {text}",
                    )
                }

                var lit = text.subslice(i, j + 1 - i)
                self.create_char(at, &lit)
                after_operator = false
                any            = true
                i              = j + 1
                continue
            }

            var k          = clang::tok::unknown
            var len: usize = 1
            var c1         = (' ' as u8)
            var c2         = (' ' as u8)
            if i + 1 < n {
                c1 = text[i + 1]
            }

            if i + 2 < n {
                c2 = text[i + 2]
            }

            // Longest match: every 3-char punctuator before any 2-char one,
            // every 2-char before the 1-char fallback. A compound operator
            // split in two (`operator + =`) is a declarator clang cannot
            // recover from: it eats the rest of the file hunting for `}`.
            //
            // The shift family only directly after `operator`: in a type,
            // `Box<Box<int>>` is two `>`, and a type is most of what this
            // tokenizes.
            if c == ('<' as u8) && c1 == ('<' as u8) && c2 == ('=' as u8) && after_operator {
                k   = clang::tok::lesslessequal
                len = 3
            } else if c == ('>' as u8) && c1 == ('>' as u8) && c2 == ('=' as u8) && after_operator {
                k   = clang::tok::greatergreaterequal
                len = 3
            } else if c == ('-' as u8) && c1 == ('>' as u8) && c2 == ('*' as u8) {
                k   = clang::tok::arrowstar
                len = 3
            } else if c == ('.' as u8) && c1 == ('.' as u8) && c2 == ('.' as u8) {
                k   = clang::tok::ellipsis
                len = 3
            } else if c == ('<' as u8) && c1 == ('=' as u8) && c2 == ('>' as u8) {
                k   = clang::tok::spaceship
                len = 3
            } else if c == ('<' as u8) && c1 == ('<' as u8) && after_operator {
                k   = clang::tok::lessless
                len = 2
            } else if c == ('>' as u8) && c1 == ('>' as u8) && after_operator {
                k   = clang::tok::greatergreater
                len = 2
            } else if c == (':' as u8) && c1 == (':' as u8) {
                k   = clang::tok::coloncolon
                len = 2
            } else if c == ('-' as u8) && c1 == ('>' as u8) {
                k   = clang::tok::arrow
                len = 2
            } else if c == ('.' as u8) && c1 == ('*' as u8) {
                k   = clang::tok::periodstar
                len = 2
            } else if c == ('&' as u8) && c1 == ('&' as u8) {
                k   = clang::tok::ampamp
                len = 2
            } else if c == ('|' as u8) && c1 == ('|' as u8) {
                k   = clang::tok::pipepipe
                len = 2
            } else if c == ('=' as u8) && c1 == ('=' as u8) {
                k   = clang::tok::equalequal
                len = 2
            } else if c == ('!' as u8) && c1 == ('=' as u8) {
                k   = clang::tok::exclaimequal
                len = 2
            } else if c == ('<' as u8) && c1 == ('=' as u8) {
                k   = clang::tok::lessequal
                len = 2
            } else if c == ('>' as u8) && c1 == ('=' as u8) {
                k   = clang::tok::greaterequal
                len = 2
            } else if c == ('+' as u8) && c1 == ('+' as u8) {
                k   = clang::tok::plusplus
                len = 2
            } else if c == ('-' as u8) && c1 == ('-' as u8) {
                k   = clang::tok::minusminus
                len = 2
            } else if c == ('+' as u8) && c1 == ('=' as u8) {
                k   = clang::tok::plusequal
                len = 2
            } else if c == ('-' as u8) && c1 == ('=' as u8) {
                k   = clang::tok::minusequal
                len = 2
            } else if c == ('*' as u8) && c1 == ('=' as u8) {
                k   = clang::tok::starequal
                len = 2
            } else if c == ('/' as u8) && c1 == ('=' as u8) {
                k   = clang::tok::slashequal
                len = 2
            } else if c == ('%' as u8) && c1 == ('=' as u8) {
                k   = clang::tok::percentequal
                len = 2
            } else if c == ('&' as u8) && c1 == ('=' as u8) {
                k   = clang::tok::ampequal
                len = 2
            } else if c == ('|' as u8) && c1 == ('=' as u8) {
                k   = clang::tok::pipeequal
                len = 2
            } else if c == ('^' as u8) && c1 == ('=' as u8) {
                k   = clang::tok::caretequal
                len = 2
            } else {
                k = self._punct_kind(c)
            }

            if k == clang::tok::unknown {
                self.ice_at(
                    at,
                    f"EmitSink::spell: unexpected byte {self._byte(c)} at offset {i} in C++ fragment ({n} bytes): [{self._bytes(text)}]",
                )
            }

            self.punct(at, k)
            if attr_open {
                if k == attr_l {
                    attr_depth += 1
                }

                if k == attr_r && attr_depth > 0 {
                    attr_depth -= 1
                    if attr_depth == 0 {
                        self.unanchored(false)
                        attr_open = false
                    }
                }
            }

            after_operator = false
            any            = true
            i += len
        }

        // A fragment that ends inside an attribute leaves no span open for
        // the next one.
        if attr_open {
            self.unanchored(false)
        }

        return any
    }

    /// `__attribute__` / `__attribute` starts at \p i of \p text, as a
    /// whole word.
    priv fn _attr_word_at(self, text: string, i: usize) -> bool {
        var j = i
        while j < text.size() && self._is_ident_char(text[j]) {
            j += 1
        }

        var w = text.subslice(i, j - i)
        return w == "__attribute__" || w == "__attribute"
    }

    priv fn _byte(self, c: u8) -> u32 {
        return c
    }

    priv fn _bytes(self, text: string) -> string {
        var out: string = ""
        for var i: usize = 0; i < text.size(); ++i {
            if i != 0 {
                out = out + " "
            }

            out = out + f"{self._byte(text[i])}"
        }

        return out
    }

    priv fn _punct_kind(self, c: u8) -> clang::tok::TokenKind {
        if c == ('{' as u8) {
            return clang::tok::l_brace
        }

        if c == ('}' as u8) {
            return clang::tok::r_brace
        }

        if c == ('(' as u8) {
            return clang::tok::l_paren
        }

        if c == (')' as u8) {
            return clang::tok::r_paren
        }

        if c == ('[' as u8) {
            return clang::tok::l_square
        }

        if c == (']' as u8) {
            return clang::tok::r_square
        }

        if c == (';' as u8) {
            return clang::tok::semi
        }

        if c == (',' as u8) {
            return clang::tok::comma
        }

        if c == (':' as u8) {
            return clang::tok::colon
        }

        if c == ('<' as u8) {
            return clang::tok::less
        }

        if c == ('>' as u8) {
            return clang::tok::greater
        }

        if c == ('*' as u8) {
            return clang::tok::star
        }

        if c == ('&' as u8) {
            return clang::tok::amp
        }

        if c == ('=' as u8) {
            return clang::tok::equal
        }

        if c == ('~' as u8) {
            return clang::tok::tilde
        }

        if c == ('!' as u8) {
            return clang::tok::exclaim
        }

        if c == ('+' as u8) {
            return clang::tok::plus
        }

        if c == ('-' as u8) {
            return clang::tok::minus
        }

        if c == ('/' as u8) {
            return clang::tok::slash
        }

        if c == ('%' as u8) {
            return clang::tok::percent
        }

        if c == ('^' as u8) {
            return clang::tok::caret
        }

        if c == ('|' as u8) {
            return clang::tok::pipe
        }

        if c == ('.' as u8) {
            return clang::tok::period
        }

        if c == ('?' as u8) {
            return clang::tok::question
        }

        return clang::tok::unknown
    }

    priv fn _is_ident_start(self, c: u8) -> bool {
        return c >= ('a' as u8) && c <= ('z' as u8)
            || c >= ('A' as u8) && c <= ('Z' as u8)
            || c == ('_' as u8)
    }

    priv fn _is_digit(self, c: u8) -> bool {
        return c >= ('0' as u8) && c <= ('9' as u8)
    }

    priv fn _is_ident_char(self, c: u8) -> bool {
        return self._is_ident_start(c) || self._is_digit(c)
    }
}
