/// --- The Kairo Project -------- Codegen/Printer/TokenStreamPrinter.k ---- ///
///
///   \brief --print-cg: show what codegen handed clang.
///
///   Two views over the same TokenSink:
///
///     code    (default)  the token stream rendered as readable C++, with
///                        the TextSink's spacing rules and brace indentation.
///                        This is the view for "why did clang say that":
///                        every clang diagnostic against an emitted TU is
///                        answered by reading this.
///     tokens             one line per token -- kind, family, Kairo span,
///                        spelling. The location instrument; the goldens
///                        that pin provenance key on it.
///
///   Neither view consults the source buffer: identifiers carry their
///   IdentifierInfo, literals their LiteralData, punctuators and keywords
///   their canonical spelling, divergent tokens their arena spelling. What
///   prints is what clang lexed, not what Kairo wrote.
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
ffi "c++" import "clang/Lex/Token.h";

import Codegen::TokenSink::*;

class TokenStreamPrinter {

    // ----------------------------------------------------------------- //
    // Shared: one token's spelling
    // ----------------------------------------------------------------- //

    /// The text clang will see for token \p i.
    static fn spelling(sink: *TokenSink, i: usize) -> string {
        var t = sink->get_token(i);
        if sink->is_divergent(i) { return sink->divergent_spelling(i); }
        if t->getKind() == clang::tok::identifier {
            var ii = t->getIdentifierInfo();
            if ii != &null { return std::nstring_to_string(ii->getName().str()); }
            return "";
        }
        if t->isLiteral() {
            if t->getLiteralData() != &null {
                return string(t->getLiteralData(), static_cast::<usize>(t->getLength()));
            }
            return "";
        }
        var p = clang::tok::getPunctuatorSpelling(t->getKind());
        if p != &null { return string(p); }
        var k = clang::tok::getKeywordSpelling(t->getKind());
        if k != &null { return string(k); }
        return "";
    }

    // ----------------------------------------------------------------- //
    // code view
    // ----------------------------------------------------------------- //

    /// No space BEFORE these.
    priv static fn _tight_before(k: clang::tok::TokenKind) -> bool {
        return (k == clang::tok::coloncolon) || (k == clang::tok::less)  || (k == clang::tok::greater)
            || (k == clang::tok::l_paren)    || (k == clang::tok::r_paren)
            || (k == clang::tok::l_square)   || (k == clang::tok::r_square)
            || (k == clang::tok::comma)      || (k == clang::tok::semi)
            || (k == clang::tok::period)     || (k == clang::tok::arrow)
            || (k == clang::tok::colon)      || (k == clang::tok::plusplus) || (k == clang::tok::minusminus);
    }

    /// No space AFTER these.
    priv static fn _tight_after(k: clang::tok::TokenKind) -> bool {
        return (k == clang::tok::coloncolon) || (k == clang::tok::less)
            || (k == clang::tok::l_paren)    || (k == clang::tok::l_square)
            || (k == clang::tok::tilde)      || (k == clang::tok::exclaim)
            || (k == clang::tok::period)     || (k == clang::tok::arrow);
    }

    priv static fn _is_word(sink: *TokenSink, i: usize) -> bool {
        var t = sink->get_token(i);
        if sink->is_divergent(i) { return true; }
        return (t->getKind() == clang::tok::identifier) || t->isLiteral()
            || (clang::tok::getKeywordSpelling(t->getKind()) != &null);
    }

    /// The token stream as C++ text. Statements and declarations break
    /// after `;`, blocks indent, `};` stays on one line. Not a formatter:
    /// good enough to read, never fed back to a compiler.
    static fn print(sink: *TokenSink, path: string) {
        std::print(f"============== CODEGEN C++: {path} ==============");

        var out    = "";
        var line   = "";
        var indent: usize = 0;
        var n      = sink->token_count();
        var prev_k = clang::tok::unknown;
        var prev_word = false;
        var at_line_start = true;

        for var i: usize = 0; i < n; ++i {
            var t = sink->get_token(i);
            var k = t->getKind();
            if k == clang::tok::eof { break; }
            var s = TokenStreamPrinter::spelling(sink, i);
            var word = TokenStreamPrinter::_is_word(sink, i);

            // `}` closes a block: dedent, own line. `};` is glued below.
            if k == clang::tok::r_brace {
                if line.size() > 0 { out += line + "\n"; line = ""; }
                if indent > 0 { indent -= 1; }
                line = TokenStreamPrinter::_pad(indent) + "}";
                // A following `;` (record definition) joins this line.
                if (i + 1 < n) && (sink->get_token(i + 1)->getKind() == clang::tok::semi) {
                    line += ";";
                    i += 1;
                }
                out += line + "\n";
                line = "";
                at_line_start = true;
                prev_k = clang::tok::r_brace;
                prev_word = false;
                continue;
            }

            // spacing
            if at_line_start {
                line = TokenStreamPrinter::_pad(indent);
                at_line_start = false;
            } else {
                var tight = TokenStreamPrinter::_tight_after(prev_k) || TokenStreamPrinter::_tight_before(k);
                // `::` glues to a preceding word only (`a, ::ns::f` stays spaced).
                if (k == clang::tok::coloncolon) && (!prev_word) { tight = false; }
                // `>` followed by a word: `Slice<int> x`, not `Slice<int>x`.
                if !tight { line += " "; }
            }
            line += s;

            if k == clang::tok::l_brace {
                out += line + "\n";
                line = "";
                indent += 1;
                at_line_start = true;
            } else if k == clang::tok::semi {
                out += line + "\n";
                line = "";
                at_line_start = true;
            }

            prev_k = k;
            prev_word = word || (k == clang::tok::greater) || (k == clang::tok::r_paren) || (k == clang::tok::r_square);
        }
        if line.size() > 0 { out += line + "\n"; }
        std::print(out);
        std::print("=========================================================");
    }

    priv static fn _pad(indent: usize) -> string {
        var s = "";
        for var i: usize = 0; i < indent; ++i { s += "    "; }
        return s;
    }

    // ----------------------------------------------------------------- //
    // tokens view
    // ----------------------------------------------------------------- //

    /// One line per token:
    ///
    ///   0006  numeric_constant  DIVERGENT  [0:30, 3)  "42"
    ///
    /// Columns: index, clang kind, family, Kairo span [fid:off, len), text.
    static fn print_tokens(sink: *TokenSink, path: string) {
        std::print(f"============== CODEGEN TOKEN STREAM: {path} ==============");
        std::print(f"-- {sink->token_count()} token(s), {sink->pending_count()} divergent --");

        var n = sink->token_count();
        for var i: usize = 0; i < n; ++i {
            var t = sink->get_token(i);
            var kind_name = string(clang::tok::getTokenName(t->getKind()));
            var family: string = ("DIVERGENT") if (sink->is_divergent(i)) else ("borrowed ");
            var spell = TokenStreamPrinter::spelling(sink, i);

            var koff: u32 = sink->kairo_offset(i);
            var klen: u32 = static_cast::<u32>(t->getLength());
            if sink->is_divergent(i) {
                for var p: usize = 0; p < sink->pending_count(); ++p {
                    var pt = sink->get_pending(p);
                    if pt->tok_index != i { continue; }
                    klen = pt->kro_len;
                    break;
                }
            }
            var kf = sink->kairo_fid(i);
            var off_s: string = ("     ?") if (koff == u32(-1)) else (f"{koff}");
            std::print(f"{i}  {kind_name}  {family}  [{kf}:{off_s}, {klen})  \x22{spell}\x22");
        }
        std::print("=========================================================");
    }
}