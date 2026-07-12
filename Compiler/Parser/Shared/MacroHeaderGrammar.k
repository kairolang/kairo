/// --- The Kairo Project ----------- Parser/Shared/MacroHeaderGrammar.k --- ///
///
///   THE token-macro header grammar: `name ! ( params )?` through the
///   closing `)` (or its absence). Body brace-balancing stays with drivers.
///
///   PP-canonical semantics (replaces the collector's parse_params /
///   parse_default_value AND the param loop in DeclParse::_parse_macro):
///     - `!` REQUIRED after the name (S037E)
///     - param := IDENT | IDENT = default | ...IDENT | ...
///     - variadic must be last; required cannot follow default
///     - default = balanced token run to `,` / `)` at depth 0, COPIED out
///
///   Precondition: caller consumed `macro` and ruled out `@` (proc macros).
///   Current token is expected to be the macro name.
///
///   Host contract: identical ig_* surface as ImportGrammar.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;

struct MacroHeaderParam {
    var name:         Token;         ///< for variadic-unnamed: the `...` token (range only)
    var variadic:     u8   = 0;      ///< 0 none / 1 named (`x...`) / 2 unnamed (`...`)
    var has_default:  bool = false;
    var default_toks: vec::<Token>;  ///< copied run; empty unless has_default
}

struct MacroHeader {
    var name:           Token;
    var params:         vec::<MacroHeaderParam>;
    var accepts_params: bool = false;
    var ok:             bool = false;
}

class <T> MacroHeaderGrammar {
    priv inline fn mhd(self) -> *T { return static_cast::<*T>(&self); }

    fn parse_macro_header(self) -> MacroHeader {
        var hdr = MacroHeader();

        // name
        if mhd()->ig_kind() != TokenKind::LitIdentifier {
            mhd()->ig_err(mhd()->ig_tok().range,
                "expected macro name after 'macro\x27", DiagID::S046E);
            return hdr;
        }
        hdr.name = mhd()->ig_tok();
        mhd()->ig_bump();

        // `!` required. canonical.
        if mhd()->ig_kind() != TokenKind::OpExclaim {
            mhd()->ig_err(hdr.name.range,
                "expected '!' after macro name", DiagID::S037E);
            return hdr;
        }
        mhd()->ig_bump();

        // optional param list
        if mhd()->ig_kind() != TokenKind::OpLParen {
            hdr.ok = true;
            hdr.accepts_params = false;
            return hdr; // parameterless form: `macro foo! { }`
        }

        hdr.accepts_params = true;
        mhd()->ig_bump_nl(); // consume `(`

        var seen_default  = false;
        var seen_variadic = false;

        while !mhd()->ig_eof() {
            var k = mhd()->ig_kind();

            if k == TokenKind::OpRParen {
                mhd()->ig_bump();
                hdr.ok = true;
                return hdr;
            }

            if (k == TokenKind::OpComma) || (k == TokenKind::TkNewLine) {
                mhd()->ig_bump();
                continue;
            }

            if seen_variadic {
                mhd()->ig_err(mhd()->ig_tok().range,
                    "no parameters allowed after a variadic (`...`) parameter",
                    DiagID::S042E);
                return hdr;
            }

            // variadic: `...ident` (named) or `...` (unnamed).
            // Prefix form, matching `fn f(...args: T)`.
            if k == TokenKind::OpEllipsis {
                if seen_default {
                    mhd()->ig_err(mhd()->ig_tok().range,
                        "variadic parameter cannot follow default parameters; place `...` after all required parameters",
                        DiagID::S042E);
                    return hdr;
                }

                var p = MacroHeaderParam();
                p.name = mhd()->ig_tok();   // range carrier for the unnamed case
                mhd()->ig_bump();           // consume `...`

                if mhd()->ig_kind() == TokenKind::LitIdentifier {
                    p.name     = mhd()->ig_tok();
                    p.variadic = 1;         // named:   `...xs`
                    mhd()->ig_bump();
                } else {
                    p.variadic = 2;         // unnamed: `...`
                }

                hdr.params.push_back(p);
                seen_variadic = true;
                continue;
            }

            if k != TokenKind::LitIdentifier {
                mhd()->ig_err(mhd()->ig_tok().range,
                    "expected a parameter name (identifier) in macro parameter list",
                    DiagID::S042E);
                return hdr;
            }

            var p = MacroHeaderParam();
            p.name = mhd()->ig_tok();
            mhd()->ig_bump();

            if mhd()->ig_eof() {
                mhd()->ig_err(p.name.range,
                    "unexpected end of tokens in macro parameter list; expected a parameter or ')\x27",
                    DiagID::S043E);
                return hdr;
            }

            var nk = mhd()->ig_kind();

            // postfix `ident...` is NOT the variadic syntax. Catch it explicitly
            // so the diagnostic points at the real mistake.
            if nk == TokenKind::OpEllipsis {
                mhd()->ig_err(p.name.range | mhd()->ig_tok().range,
                    "variadic parameters use a prefix '...': write '...name', not 'name...\x27",
                    DiagID::S042E);
                return hdr;
            }

            // default: `ident = <balanced run>`
            if nk == TokenKind::OpEqual {
                mhd()->ig_bump(); // consume `=`
                if !self._collect_default(&p) { return hdr; }
                p.has_default = true;
                seen_default  = true;
                hdr.params.push_back(p);
                continue;
            }

            // plain required
            if seen_default {
                mhd()->ig_err(p.name.range,
                    "required parameter cannot follow a parameter with a default value; reorder parameters so defaults come last",
                    DiagID::S042E);
                return hdr;
            }
            hdr.params.push_back(p);
        }

        mhd()->ig_err(hdr.name.range,
            "unterminated macro parameter list; expected ')' to close it",
            DiagID::S043E);
        return hdr;
    }

    /// \brief copies a balanced default-value token run into p->default_toks.
    ///        stops at `,` or the param list's `)` at depth 0 (unconsumed).
    priv fn _collect_default(self, p: *MacroHeaderParam) -> bool {
        var depth: i32 = 0;
        var count: usize = 0;
        var eq_range = p->name.range;

        while !mhd()->ig_eof() {
            var k = mhd()->ig_kind();

            if (k == TokenKind::OpLParen) || (k == TokenKind::OpLBrace)
            || (k == TokenKind::OpLSquare) { depth += 1; }

            if k == TokenKind::OpRParen {
                if depth == 0 { break; } // closes the param list leave it
                depth -= 1;
            }
            if k == TokenKind::OpRBrace  { depth -= 1; }
            if k == TokenKind::OpRSquare { depth -= 1; }

            if (k == TokenKind::OpComma) && (depth == 0) { break; }

            p->default_toks.push_back(mhd()->ig_tok());
            count += 1;
            mhd()->ig_bump();
        }

        if count == 0 {
            mhd()->ig_err(eq_range,
                "empty default value expression; provide at least one token after '=\x27",
                DiagID::S044E);
            return false;
        }
        return true;
    }
}