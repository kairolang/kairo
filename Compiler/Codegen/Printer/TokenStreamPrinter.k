/// --- The Kairo Project -------- Codegen/Printer/TokenStreamPrinter.k ---- ///
///
///   \brief --print-cg: dump the emitted token stream. Kind, spelling,
///          loc-family, and Kairo span for every token.
///
///   \par Why this exists BEFORE the emitters
///     Every emitter bug in this codegen model is a location bug, and a
///     location bug with no stream dump is indistinguishable from a
///     structural codegen bug. This is the instrument; it gets built first.
///
///   \par The M2 regression test
///     Emitter output for m1_hello.k must be BYTE-IDENTICAL to the M1
///     hand-written stream. This printer produces the comparable form.
///     Diff that, and the first real codegen regression test exists.
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

    /// One line per token:
    ///
    ///   0000  kw_int          borrowed  [   0,   2)  "int"
    ///   0001  identifier      borrowed  [   3,   4)  "main"
    ///   0006  numeric_const   DIVERGENT [  30,   3)  "42"
    ///
    /// Columns: index, clang kind name, loc family, Kairo span [off, len),
    /// spelling. Divergent tokens show the ARENA spelling; borrowed tokens
    /// show the clang kind's canonical spelling where one exists (punctuators
    /// and keywords) and "" otherwise   the Kairo bytes are already located
    /// by the span, so re-reading them here would just duplicate the source.
    static fn print(sink: *TokenSink, path: string) {
        std::print(f"============== CODEGEN TOKEN STREAM: {path} ==============");
        std::print(f"-- {sink->token_count()} token(s), {sink->pending_count()} divergent --");

        var n = sink->token_count();
        for var i: usize = 0; i < n; ++i {
            var t = sink->get_token(i);

            var kind_name = string(clang::tok::getTokenName(t->getKind()));

            // Spelling: every family answers, because a dump with blank
            // columns cannot catch the bugs it exists to catch. An identifier
            // carries its IdentifierInfo and a literal its LiteralData, so
            // nothing here needs the source buffer.
            var family: string = "borrowed ";
            var spell:  string = "";

            if sink->is_divergent(i) {
                family = "DIVERGENT";
                spell  = sink->divergent_spelling(i);
            } else if t->getKind() == clang::tok::identifier {
                var ii = t->getIdentifierInfo();
                if ii != &null {
                    spell = std::nstring_to_string(ii->getName().str());
                }
            } else if t->isLiteral() {
                if t->getLiteralData() != &null {
                    spell = string(t->getLiteralData(),
                                   static_cast::<usize>(t->getLength()));
                }
            } else {
                var p = clang::tok::getPunctuatorSpelling(t->getKind());
                if p != &null {
                    spell = string(p);
                } else {
                    var k = clang::tok::getKeywordSpelling(t->getKind());
                    if k != &null { spell = string(k); }
                }
            }

            // Kairo span. The offset comes from the sink for BOTH families
            // (it decomposes the token's expansion loc); divergent tokens
            // additionally carry an explicit Kairo length in their pending
            // record, since their C++ length is the arena spelling's.
            //
            // Printing "?" for borrowed offsets, as this used to, hid the one
            // bug this dump exists to catch: an off-by-one in the global ->
            // file-relative offset conversion shifted every borrowed token by
            // a byte, and the column that would have shown it was blank.
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

            var off_s: string = ("     ?") if (koff == u32(-1)) else (f"{koff}");
            std::print(f"{i}  {kind_name}  {family}  [{off_s}, {klen})  \x22{spell}\x22");
        }

        std::print("=========================================================");
    }
}