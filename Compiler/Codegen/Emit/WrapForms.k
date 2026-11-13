/// --- The Kairo Project --------------------- Codegen/Emit/WrapForms.k --- ///
///
///   \brief Kairo's builtin operators on an operand whose type C++ decides:
///          a duck generic body's (EmitIR) and a witness's native operator
///          (EmitWitness), spelled by one set of forms.
///
///   \detail
///     Integer `+ - *`, unary `-` and `~`, and the shifts wrap; division
///     and remainder check a zero divisor and `MIN / -1`
///     (Compiler/Spec/Codegen.md, the wrap forms). Each form opens with an
///     `if constexpr` on the operand's type, so the integer arm and the
///     type's own operator live in one body and clang keeps only the one
///     the type takes. A witness's form is a generic lambda: a full
///     specialization's member is not a template, and only a template's
///     discarded branch goes uninstantiated.
///
///   Import law: CodegenContext only.
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

import AST::LangItems::LowerTargets
import AST::OperatorFacts::OperatorFacts
import Codegen::Sink::EmitSink::EmitSink
import Location::SourceRange::SourceRange
import Token::TokenKind::TokenKind

pub class WrapForms {
    /// `using T = ...; if constexpr (T is a non-bool integer) { using U = ...;`
    /// opened inside the lambda; \p a names the bound operand T is read off.
    pub static fn open(s: unsafe *EmitSink, at: SourceRange, const a: string, d: u32) {
        var tt = LowerTargets::wrap_tmp("T", d)
        var uu = LowerTargets::wrap_tmp("U", d)
        s->spell(at, "using " + tt + " = __remove_cvref(decltype(" + a + ")); ")
        s->spell(
            at,
            "if constexpr (__is_integral(" + tt + ") && (!__is_same(" + tt + ", bool))) { ",
        )

        // `__make_unsigned(T){}` does not parse as an operand; a cast does.
        s->spell(
            at,
            "using " + uu + " = decltype(static_cast<__make_unsigned(" + tt + ")>(0) + 0u); ",
        )
    }

    priv static fn _scs(const ty: string, const x: string) -> string {
        return "static_cast<" + ty + ">(" + x + ")"
    }

    /// The integer arm's value of op \p k on bound operands \p a and \p b (the
    /// lambda's T and U at depth \p d), returned.
    pub static fn int_arm(s:       unsafe *EmitSink,
                          at:      SourceRange,
                          k:       TokenKind,
                          const a: string,
                          const b: string,
                          d:       u32) {
        var tt = LowerTargets::wrap_tmp("T", d)
        var uu = LowerTargets::wrap_tmp("U", d)
        if k == TokenKind::OpSlash || k == TokenKind::OpPercent {
            var rem = k == TokenKind::OpPercent
            s->spell(
                at,
                "if (" + LowerTargets::clang_expect() + "(" + b + " == 0, 0)) ::" + LowerTargets::div_zero_fn() + "(); ",
            )

            s->spell(
                at,
                "if constexpr (__is_signed(" + tt + ")) { if (" + b + " == " + WrapForms::_scs(
                    tt,
                    "-1",
                ) + ") { return ",
            )

            if rem {
                s->spell(at, WrapForms::_scs(tt, "0"))
            } else {
                s->spell(
                    at,
                    WrapForms::_scs(
                        tt,
                        WrapForms::_scs(uu, "0") + " - " + WrapForms::_scs(
                            uu,
                            a,
                        ),
                    ),
                )
            }

            s->spell(
                at,
                "; } } return " + WrapForms::_scs(
                    tt,
                    a + (if (rem) => (" % ") else => " / ") + b,
                ) + "; ",
            )

            return
        }

        if k == TokenKind::OpLessLess || k == TokenKind::OpGreaterGreater {
            // _shift_form per instance (SHIFT spec §3.3): R from T's size,
            // as CXXSpell::reg_width computes it, and a signed `>>` through
            // S, U's signed twin (U is already promoted to at least
            // `unsigned`, so S is at least `int`: the sign-extension).
            var rr   = LowerTargets::wrap_tmp("R", d)
            var ss   = LowerTargets::wrap_tmp("S", d)
            var bits = "sizeof(" + tt + ") * 8"
            s->spell(
                at,
                "constexpr auto " + rr + " = (" + bits + " > 128) ? " + bits + " : ((" + bits + " > 64) ? 128 : ((" + bits + " < 32) ? 32 : " + bits + ")); ",
            )

            var mask = "(" + WrapForms::_scs(uu, b) + " & " + WrapForms::_scs(
                uu,
                rr + " - 1",
            ) + ")"
            if k == TokenKind::OpLessLess {
                s->spell(
                    at,
                    "return static_cast<" + tt + ">(" + WrapForms::_scs(uu, a),
                )

                s->punct(at, clang::tok::lessless)
                s->spell(at, mask + "); ")
                return
            }

            s->spell(at, "if constexpr (__is_signed(" + tt + ")) { ")
            s->spell(at, "using " + ss + " = __make_signed(" + uu + "); ")
            s->spell(
                at,
                "return static_cast<" + tt + ">(" + WrapForms::_scs(ss, a),
            )

            s->punct(at, clang::tok::greatergreater)
            s->spell(at, mask + "); } ")
            s->spell(
                at,
                "return static_cast<" + tt + ">(" + WrapForms::_scs(uu, a),
            )

            s->punct(at, clang::tok::greatergreater)
            s->spell(at, mask + "); ")
            return
        }

        var sym = if (k == TokenKind::OpPlus) => ("+")
                  else => (if (k == TokenKind::OpMinus) => ("-") else => "*")
        s->spell(
            at,
            "return " + WrapForms::_scs(
                tt,
                WrapForms::_scs(uu, a) + " " + sym + " " + WrapForms::_scs(
                    uu,
                    b,
                ),
            ) + "; ",
        )
    }

    /// T's own op \p k on \p a and \p b, as text (shifts are punctuators).
    pub static fn native(s:       unsafe *EmitSink,
                         at:      SourceRange,
                         k:       TokenKind,
                         const a: string,
                         const b: string) {
        if k == TokenKind::OpLessLess {
            s->spell(at, a)
            s->punct(at, clang::tok::lessless)
            s->spell(at, b)
            return
        }

        if k == TokenKind::OpGreaterGreater {
            s->spell(at, a)
            s->punct(at, clang::tok::greatergreater)
            s->spell(at, b)
            return
        }

        var sym = "+"
        if k == TokenKind::OpMinus {
            sym = "-"
        }

        if k == TokenKind::OpStar {
            sym = "*"
        }

        if k == TokenKind::OpSlash {
            sym = "/"
        }

        if k == TokenKind::OpPercent {
            sym = "%"
        }

        s->spell(at, a + " " + sym + " " + b)
    }

    /// # a builtin's operator as a witness member

    /// \p k's C++ spelling, for the operators C++ spells as Kairo does.
    priv static fn _sym(k: TokenKind) -> string {
        match k {
            case TokenKind::OpEqualEqual {
                return "=="
            } case TokenKind::OpExclaimEqual {
                return "!="
            } case TokenKind::KwNotEq {
                return "!="
            } case TokenKind::OpLess {
                return "<"
            } case TokenKind::OpGreater {
                return ">"
            } case TokenKind::OpLessEqual {
                return "<="
            } case TokenKind::OpGreaterEqual {
                return ">="
            } case TokenKind::OpAmp {
                return "&"
            } case TokenKind::KwBitand {
                return "&"
            } case TokenKind::OpPipe {
                return "|"
            } case TokenKind::KwBitor {
                return "|"
            } case TokenKind::OpCaret {
                return "^"
            } case TokenKind::KwXor {
                return "^"
            } default {
                return ""
            }
        }
    }

    priv static fn _is_cmp(k: TokenKind) -> bool {
        return k == TokenKind::OpEqualEqual
            || k == TokenKind::OpExclaimEqual
            || k == TokenKind::KwNotEq
            || k == TokenKind::OpLess
            || k == TokenKind::OpGreater
            || k == TokenKind::OpLessEqual
            || k == TokenKind::OpGreaterEqual
    }

    /// The C++ test that \p S (a witness's `Self`) has op \p k of
    /// \p arity operands (the receiver aside) built in, as Kairo's builtin
    /// of that C++ type has it (ConformanceChecking::_builtin_op_result):
    /// what lets a type C++ instantiates a bounded template with, which no
    /// Kairo row names, meet the bound through its own operator. "" when
    /// no builtin has the operator.
    pub static fn witness_gate(k: TokenKind, arity: usize, const S: string) -> string {
        var b = OperatorFacts::compound_base(k)
        if b != TokenKind::TkUnknown {
            if arity != 1 {
                return ""
            }

            return WrapForms::witness_gate(b, 1, S)
        }

        var ints = "(__is_integral(" + S + ") && !__is_same(" + S + ", bool) && !__is_same(" + S + ", char) && !__is_same(" + S + ", wchar_t) && !__is_same(" + S + ", char8_t) && !__is_same(" + S + ", char16_t) && !__is_same(" + S + ", char32_t))"
        var num = "(" + ints + " || __is_floating_point(" + S + "))"
        if arity == 0 {
            if k == TokenKind::OpMinus {
                return "((" + ints + " && __is_signed(" + S + ")) || __is_floating_point(" + S + "))"
            }

            if k == TokenKind::OpPlus {
                return num
            }

            if k == TokenKind::OpTilde || k == TokenKind::KwCompl {
                return ints
            }

            return ""
        }

        if arity != 1 {
            return ""
        }

        if k == TokenKind::OpEqualEqual
            || k == TokenKind::OpExclaimEqual
            || k == TokenKind::KwNotEq {
            return "(__is_arithmetic(" + S + ") || __is_pointer(" + S + "))"
        }

        if WrapForms::_is_cmp(k) {
            return "((__is_arithmetic(" + S + ") && !__is_same(" + S + ", bool)) || __is_pointer(" + S + "))"
        }

        if k == TokenKind::OpLessEqualGreater {
            return "(" + ints + " || __is_same(" + S + ", bool) || __is_same(" + S + ", char32_t))"
        }

        if k == TokenKind::OpPlus
            || k == TokenKind::OpMinus
            || k == TokenKind::OpStar
            || k == TokenKind::OpSlash {
            return num
        }

        if k == TokenKind::OpPercent
            || k == TokenKind::OpLessLess
            || k == TokenKind::OpGreaterGreater {
            return ints
        }

        if WrapForms::_sym(k).size() > 0 { // `&`, `|`, `^`
            return "(" + ints + " || __is_same(" + S + ", bool))"
        }

        return ""
    }

    /// The value of builtin op \p k on receiver \p r and, for \p arity 1,
    /// operand \p o, as the witness member returns it: the form Kairo's own
    /// operator takes on the receiver's type, \p ret naming the result
    /// (`Ordering` for `<=>`). A compound assignment is the binary form
    /// stored back, as a value-less `(void)` expression.
    pub static fn witness_op(s:         unsafe *EmitSink,
                             at:        SourceRange,
                             k:         TokenKind,
                             arity:     usize,
                             const r:   string,
                             const o:   string,
                             const ret: string) {
        var b = OperatorFacts::compound_base(k)
        if b != TokenKind::TkUnknown {
            s->spell(at, "(void)(" + r + " = ")
            WrapForms::witness_op(s, at, b, 1, r, o, ret)
            s->spell(at, ")")
            return
        }

        var self_t = "__remove_cvref(decltype(" + r + "))"
        if arity == 0 && k == TokenKind::OpPlus {
            s->spell(at, WrapForms::_scs(self_t, "+" + r))
            return
        }

        var aa = LowerTargets::wrap_tmp("a", 0)
        var bb = LowerTargets::wrap_tmp("b", 0)
        var tt = LowerTargets::wrap_tmp("T", 0)
        var uu = LowerTargets::wrap_tmp("U", 0)
        if arity == 0 { // `-` or `~`
            var sym = if (k == TokenKind::OpMinus) => ("-") else => "~"
            var iv = if (k == TokenKind::OpMinus) => (WrapForms::_scs(
                         uu,
                         "0",
                     ) + " - " + WrapForms::_scs(uu, aa))
                     else => "~" + WrapForms::_scs(uu, aa)
            s->spell(at, "[](auto&& " + aa + ") { ")
            WrapForms::open(s, at, aa, 0)
            s->spell(
                at,
                "return " + WrapForms::_scs(tt, iv) + "; } else { return " + WrapForms::_scs(
                    tt,
                    sym + aa,
                ) + "; } }(" + r + ")",
            )

            return
        }

        if WrapForms::_is_cmp(k) {
            s->spell(at, "(" + r + " " + WrapForms::_sym(k) + " " + o + ")")
            return
        }

        if k == TokenKind::OpLessEqualGreater {
            var kr = LowerTargets::wrap_tmp("r", 0)
            s->spell(
                at,
                "[](auto " + kr + ") { return static_cast<" + ret + ">((" + kr + " > 0) - (" + kr + " < 0)); }((" + r + " <=> " + o + "))",
            )

            return
        }

        if WrapForms::_sym(k).size() > 0 { // `&`, `|`, `^`: no wrap to do
            s->spell(
                at,
                WrapForms::_scs(self_t, r + " " + WrapForms::_sym(k) + " " + o),
            )

            return
        }

        s->spell(at, "[](auto&& " + aa + ", auto&& " + bb + ") { ")
        WrapForms::open(s, at, aa, 0)
        WrapForms::int_arm(s, at, k, aa, bb, 0)
        s->spell(at, "} else { return ")
        WrapForms::native(s, at, k, aa, bb)
        s->spell(at, "; } }(" + r + ", " + o + ")")
    }
}
