/// --- The Kairo Project ----------------------- Sema/Type/CastTyping.k --- ///
///
///   \brief The `as` family. The written target is the result type, always.
///
///   \detail
///     Dispatch on (source, target), first match, no fallthrough:
///
///       1. target = source + const           const cast (one-way); on a
///                                            pointee too, by [conv.qual].
///                                            A drop at any level is an
///                                            error naming `as unsafe *`
///       2. target is `unsafe *X`             reinterpret; U: needs unsafe ctx
///       3. target is `*X`, source `*S`,
///          S/X derives-related               upcast: static, lint redundant
///                                            downcast: ASSERTING, crashes on a
///                                            miss (SC001W), S polymorphic
///       3b. target is `*X`, X a generic      the CRTP downcast: static, no
///           parameter whose `derives`        vtable, no `unsafe`; a `: type`
///           bound reaches S                  X is C++'s to check (D1)
///       4. target is `*X?`, same relation    checked downcast, null on miss
///       5. static ladder: lattice I/W (lint) / E / U / X -> plain enum <->
///          exact underlying -> `op as` on the source -> one-param ctor on
///          the target -> error.  `op as` beats ctor.
///
///     Integer -> Kairo enum needs EXACTLY the enum's underlying type (the
///     `derives` type, `u32` when defaulted); anything else is SC127E with a
///     fix-it casting to the underlying type first. An imported C++ enum
///     keeps SC092E for the same mismatch.
///
///     Into a CLOSED plain enum (the default; EnumDecl::is_open is false)
///     the value must be one of its variants', so a closed enum never holds
///     another and its spare values are a niche (EnumNiche). A constant
///     operand is checked here: a miss is SC252E with a fix-it
///     adding `@open` to an enum this file declares. Any other operand is
///     given TypeCastExpr::enum_check and checked at run time
///     (OperatorLowering), crashing on a miss. An `@open` enum (and every
///     imported one) holds any value of its underlying type, as in C++:
///     the cast never fails and never checks.
///
///     `as static T` runs the ladder with 3-4 disabled and errors when the
///     answer would have been dynamic; a static downcast is forbidden
///     outright (it is a reinterpret wearing a hat). `as const T` asserts 1.
///     `T? as T` is an error naming `??` / `!`; there is no collapsing cast.
///
///     Pointer <-> integer: `ptr as usize` needs no unsafe; `ptr as u8` is an
///     error, not a warning; `int as unsafe *T` needs unsafe; `int as *T` is
///     an error; `*T as unsafe *T` needs unsafe, and so does the way back,
///     `unsafe *T as *T` (same pointee, cv kept).
///
///     Which of the four the source wrote is `TypeCastExpr::mode`; the
///     parser leaves `const` / `unsafe` in the target's qualifiers too, so
///     the const rung can compare the WRITTEN type and `as unsafe *T` lands
///     on the `unsafe *T` canonical rather than on `*T` plus a bit.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import AST::Context::SymbolTable::DeclName
import AST::DeclFacts::decl_generic_params
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    canon_has_const,
    canon_quals,
    canon_unqual,
}
import AST::Node::Casting::{
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    EnumDecl,
    FunctionDecl,
    GenericParamKindBound,
    ParamDecl,
    TransferKind,
}
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    CastMode,
    IfExpr,
    TypeCastExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr,
    CharacterLiteralExpr,
    FloatingLiteralExpr,
    IntegerLiteralExpr,
    NullLiteralExpr,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    FunctionPointerType,
    GenericParamType,
}
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Check::ConstEval::ConstEval
import Sema::Resolve::NameLookup::NameLookup
import Sema::Type::Conversion::{
    ConvClass,
    ImplicitRank,
}
import Sema::Type::OverloadResolution::{
    ArgInfo,
    OvlOutcome,
}
import Sema::Type::Substitution::Substitution
import Token::TokenKind::TokenKind

// TODO(DUCK-GENERIC): T uses arg_info, conv, defer_enum_cast, fail, finish_call_args, fn_return_type, in_unsafe, mark_unknown, ml, needs_bound, note_panic_site, ovl, ... (17). Stage 0 was duck-typed; bound it or keep `: type`.
pub class <T: type> CastTyping {
    @move
    fn CastTyping(self, other: Self) = default
    fn CastTyping(self) = default
    priv inline fn dyn(self) -> unsafe *T {
        return unsafe ((&self) as *T)
    }

    fn type_cast(self, n: unsafe *TypeCastExpr, expected: unsafe *Type) -> unsafe *Type {
        if n->target == &null || n->target->is_poisoned() {
            self.dyn()->type_of(n->operand, &null)
            self.dyn()->poison_only(n)
            return &null
        }

        var unsafe *target = n->target->canonical
        if target == &null {
            self.dyn()->type_of(n->operand, &null)
            self.dyn()->mark_unknown(n) // dependent target: M2.
            return &null
        }

        var mode              = n->mode
        var target_unsafe_ptr = mode == CastMode::Unsafe || self.dyn()->tu.is_unsafe_ptr(target)

        // The literal-takes-the-type rule applies through a cast too: `10 as u8`
        // is a u8 literal, not an i32 narrowed. Into a plain enum the literal
        // takes the enum's underlying type, the one rung 5b accepts: `3 as
        // Color` is the u8 3, so a closed enum can check it as a constant.
        var unsafe *op_expected = target
        var ped = dyn_cast<EnumDecl>(
            self.dyn()->tu.record_decl(self.dyn()->tu.strip_nullable(target)),
        )

        if ped != &null && !ped->is_adt && !ped->is_imported() {
            op_expected = self._enum_underlying(ped)
        }

        // Into `char` an explicit `as` from an integer literal is the u32 to
        // char conversion, which is UNCHECKED (decided 2026-11-04: `0xFFFFFFFF
        // as char` is the sentinel, not a trap). The scalar-value range
        // test belongs to the IMPLICIT literal adaptation only, so the
        // literal is typed as the u32 it must fit and the cast does the rest.
        if self.dyn()->tu.is_builtin(canon_unqual(target), BuiltinKind::Char)
            && isa<IntegerLiteralExpr>(self.dyn()->tu.strip_parens(n->operand)) {
            op_expected = self.dyn()->tu.builtin(BuiltinKind::U32)
        }

        var src = self.dyn()->type_of(n->operand, op_expected)
        if self.dyn()->propagate(n, n->operand) {
            return &null
        }

        if src == &null {
            return &null
        }

        // A C++ reference converts as what it refers to: `v[i] as i64` with
        // `v[i]: u32&` is a cast of the u32, as in C++.
        var src_c = canon_unqual(src)
        if src_c != &null && (isa<CXXLValueRefType>(src_c) || isa<CXXRValueRefType>(src_c)) {
            src = self.dyn()->tu.as_value(src_c)
        }

        // A non-nullable POINTER target consumes the operand's value: a
        // nullable pointer proven non-null here (`if p == &null { return }`
        // above) casts as its `*T`, as `p->x` there reads it.
        // Unproven, it stays the `*T?` and the rungs below say why it does
        // not convert. An integer target is left alone: a nullable has no
        // cast to an integer at all, proven or not (casting.mdx; the
        // `n as usize` case of Tests/Sema/ExprTyper/ptr_to_int_errors.k).
        if self.dyn()->tu.nullable_inner(target) == &null
            && self.dyn()->tu.pointee(target) != &null {
            src = self.dyn()->value_if_proven(n->operand, src)
        }

        if src == target {
            // A literal takes its type from the cast (`0 as usize` is a usize
            // literal, not an i32), so against no slot that already holds the
            // type -- `var i = 0 as usize`, `(1 as u64) << 63`, a range bound,
            // an overloaded callee -- removing the cast changes what the code
            // means. It is redundant only into a slot of exactly that type.
            if self._is_literal_shape(n->operand) {
                n->widening = true
                if expected != &null && canon_unqual(expected) == canon_unqual(target) {
                    self._lint_redundant(n, src, target)
                }

                return target
            }

            self._lint_redundant(n, src, target)
            return target
        }

        // 1. const cast, one-way: the target is the operand's own type with
        //    qualifiers added. Read off the canonicals: `as const T` is
        //    qualified(CONST, T) against a T.
        if canon_unqual(target) == canon_unqual(src)
            && (canon_quals(src) & ~canon_quals(target)) == 0 {
            return target
        }

        // 1b. the same, one level down: `*T as *const T`. The top-level
        //     rung above only sees the pointer's own cv, so without this a
        //     pointee qualifier fell through to the record rung and read as
        //     "unrelated types". Adding follows [conv.qual]; dropping at any
        //     level -- including a drop hidden beside an addition at another
        //     level -- is not a const cast and stays behind `as unsafe *`.
        if !self.dyn()->tu.is_unsafe_ptr(target)
            && mode != CastMode::Unsafe
            && self._same_pointer_shape(src, target) {
            if self.dyn()->conv.qualification(src, target) {
                return target
            }

            self._qual_cast_error(n, src, target)
            return &null
        }

        if mode == CastMode::Const {
            self.dyn()->fail(
                n,
                DiagID::SC030E,
                f"'as const' only adds qualifiers: '{self.dyn()->tu.str(target)}' is not '{self.dyn()->tu.str(src)}' with 'const' added",
            )

            return &null
        }

        // 2. reinterpret to `unsafe *X`.
        if target_unsafe_ptr && self.dyn()->tu.pointee(target) != &null {
            if self.dyn()->tu.pointee(src) == &null && !self.dyn()->tu.is_integer(src) {
                self.dyn()->fail(
                    n,
                    DiagID::SC026E,
                    f"only a pointer or an integer can be cast to '{self.dyn()->tu.str(target)}'; '{self.dyn()->tu.str(src)}' is neither",
                )

                return &null
            }

            if !self.dyn()->in_unsafe() {
                self.dyn()->sc->diag->report(
                    DiagID::SC023E,
                    n->range.start,
                    f"cast to '{self.dyn()->tu.str(target)}' requires an unsafe context",
                ).first(n->range)->note(
                    n->range.start,
                    "wrap the expression in 'unsafe { ... }'; this cast discards pointer provenance",
                )->emit()
                n->poison()
                return &null
            }

            // Between related records the address is a base subobject's,
            // not the same bits: C++'s static_cast moves it, a reinterpret
            // does not, and only a first base sits at offset 0. Either
            // direction -- the downcast is the unchecked one the spelling
            // asks for, but still to the right address.
            var rsp = self.dyn()->tu.pointee(src)
            var rtp = self.dyn()->tu.pointee(target)
            if rsp != &null && rtp != &null {
                var rsd = self.dyn()->tu.record_decl(rsp)
                var rtd = self.dyn()->tu.record_decl(rtp)
                if rsd != &null && rtd != &null && rsd != rtd {
                    if Substitution(self.dyn()->sc).derives_from(rsp, rtp)
                        || Substitution(self.dyn()->sc).derives_from(rtp, rsp) {
                        n->base_adjust = true
                    }
                }
            }

            return target
        }

        // 3 / 4. pointer casts between related records.
        var sp = self.dyn()->tu.pointee(src)
        var tp = self.dyn()->tu.pointee(self.dyn()->tu.strip_nullable(target))
        if sp != &null && tp != &null {
            if self.dyn()->tu.is_unsafe_ptr(src) {
                // raw -> safe: the mirror of `as unsafe *T`, and the only way
                // memory born raw (every C allocation) becomes a safe pointer.
                // The `unsafe` block is the programmer's claim that the
                // pointer is valid; this cast is what the claim is about.
                // When AMT can adopt a pointer, the adoption hooks this
                // spelling -- the checked construction gets a new lowering,
                // not a new syntax. Same pointee only, cv kept by the rule-1b
                // test: retyping or dropping `const` is still `as unsafe *`.
                var raw_twin = self.dyn()->sc->types->pointer(tp, true)
                if !self._same_pointer_shape(src, raw_twin) {
                    self.dyn()->fail(
                        n,
                        DiagID::SC091E,
                        f"cannot cast '{self.dyn()->tu.str(src)}' to '{self.dyn()->tu.str(target)}': a raw pointer becomes safe only with its own pointee; reinterpret with 'as unsafe *' first",
                    )

                    return &null
                }

                if !self.dyn()->conv.qualification(src, raw_twin) {
                    self._qual_cast_error(n, src, target)
                    return &null
                }

                if !self.dyn()->in_unsafe() {
                    self.dyn()->sc->diag->report(
                        DiagID::SC023E,
                        n->range.start,
                        f"cast from the raw pointer '{self.dyn()->tu.str(src)}' to the safe pointer '{self.dyn()->tu.str(target)}' requires an unsafe context",
                    ).first(n->range)->note(
                        n->range.start,
                        "wrap it in 'unsafe { ... }': the block is your claim that the pointer is valid",
                    )->emit()
                    n->poison()
                    return &null
                }

                return target
            }

            var sd          = self.dyn()->tu.record_decl(sp)
            var td          = self.dyn()->tu.record_decl(tp)
            var to_nullable = self.dyn()->tu.nullable_inner(target) != &null
            if sd == &null || td == &null {
                // A pointee that is a generic parameter: which classes meet is
                // the instance's question. The checked form is a dynamic_cast
                // either way, which C++ checks per instance (an upcast or the
                // same class passes, an unrelated or non-polymorphic downcast
                // is its error there).
                if to_nullable && (sp->is_dependent() || tp->is_dependent()) {
                    n->checked_downcast = true
                    return target
                }

                // 3b. the CRTP downcast: `&self as *X` in a base whose X is
                //     bounded `derives Mixin<X>`. The bound proves every X
                //     is a Mixin<X>, so the target is known statically and
                //     the cast is C++'s static_cast (EmitIR's default kind),
                //     with no vtable and no `unsafe`. A reinterpret there is
                //     wrong, not just unsafe: a mixin that is not the first
                //     base sits at a nonzero offset.
                if !to_nullable && sd != &null && self._bound_downcast(sp, tp) {
                    if (canon_quals(sp) & ~canon_quals(tp)) != 0 {
                        self._qual_cast_error(n, src, target)
                        return &null
                    }

                    return target
                }

                if self.dyn()->tu.is_void(tp) {
                    self.dyn()->fail(
                        n,
                        DiagID::SC091E,
                        f"cannot cast '{self.dyn()->tu.str(src)}' to the safe pointer '{self.dyn()->tu.str(target)}'; erasing the pointee type needs 'as unsafe *void' inside an 'unsafe' block",
                    )

                    return &null
                }

                self.dyn()->fail(
                    n,
                    DiagID::SC091E,
                    f"pointer cast between unrelated types '{self.dyn()->tu.str(src)}' and '{self.dyn()->tu.str(target)}'; use 'as unsafe *' to reinterpret",
                )

                return &null
            }

            if Substitution(self.dyn()->sc).derives_from(sp, tp) {
                // upcast: static, implicit already does it.
                self._lint_widening(n, src, target, expected)
                return target
            }

            if Substitution(self.dyn()->sc).derives_from(tp, sp) {
                if mode == CastMode::Static {
                    self.dyn()->sc->diag->report(
                        DiagID::SC024E,
                        n->range.start,
                        f"static downcast from '{self.dyn()->tu.str(src)}' to '{self.dyn()->tu.str(target)}' is not allowed",
                    ).first(n->range)->note(
                        n->range.start,
                        "write 'as *X' for a checked cast that crashes on a miss, 'as *X?' for one that yields null, or 'as unsafe *X' to reinterpret",
                    )->emit()
                    n->poison()
                    return &null
                }

                if !self.dyn()->tu.is_polymorphic(sd) {
                    self.dyn()->sc->diag->report(
                        DiagID::SC025E,
                        n->range.start,
                        f"cannot downcast from '{self.dyn()->tu.str(src)}': '{self.dyn()->tu.decl_name(sd)}' has no virtual methods, so there is no runtime type to check",
                    ).first(n->range)->note(sd->range.start, "declared here")->first(
                        sd->range,
                    )->emit()
                    n->poison()
                    return &null
                }

                if !to_nullable {
                    self.dyn()->note_panic_site(n) // PanicEffectChecking reads it.
                    // Compiler/Spec/Panic.md#crashes-are-not-panics: a miss CRASHES (OperatorLowering builds the
                    // check), joins no panic set, and always warns: the
                    // checked form says what to do on a miss instead.
                    n->asserting_downcast = true
                    self._warn_asserting_downcast(n, td)
                } else {
                    n->checked_downcast = true
                }

                return target
            }

            self.dyn()->fail(
                n,
                DiagID::SC091E,
                f"'{self.dyn()->tu.decl_name(sd)}' and '{self.dyn()->tu.decl_name(td)}' are unrelated; use 'as unsafe *' to reinterpret",
            )

            return &null
        }

        // pointer -> integer, integer -> pointer
        if sp != &null && self.dyn()->tu.is_integer(target) {
            if self.dyn()->tu.kind_of(target) != BuiltinKind::USize {
                // Every other integer is refused, u64 and isize included:
                // usize is the one type that holds an address on every
                // target, and the two-step spelling is the honest one.
                var ts = self.dyn()->tu.str(target)
                var b = self.dyn()->sc->diag->report(
                    DiagID::SC026E,
                    n->range.start,
                    f"a pointer converts to 'usize' only; write 'as usize as {ts}' if you mean to narrow the address",
                )

                b.first(n->range, f"pointer cast to '{ts}'")
                b.note(
                    n->operand->range.start,
                    f"'{self.dyn()->tu.str(src)}' is a pointer; its address is a 'usize', and narrowing that is an ordinary integer cast",
                )

                if n->target != &null && n->target->range.is_valid() {
                    b.insert(
                        n->target->range.start,
                        "usize as ",
                        "read the address as 'usize' first",
                    )
                }

                b.emit()
                n->poison()
                return &null
            }

            return target
        }

        if tp != &null && self.dyn()->tu.is_integer(src) {
            self.dyn()->sc->diag->report(
                DiagID::SC026E,
                n->range.start,
                f"cannot cast the integer type '{self.dyn()->tu.str(src)}' to the safe pointer '{self.dyn()->tu.str(target)}'; only 'as unsafe *T' can turn an integer into an address",
            ).first(n->range)->emit()
            n->poison()
            return &null
        }

        // 5. the static ladder.
        // 5a. lattice
        var sk = self.dyn()->tu.kind_of(src)
        var tk = self.dyn()->tu.kind_of(self.dyn()->tu.strip_nullable(target))
        if sk != BuiltinKind::COUNT && tk != BuiltinKind::COUNT {
            var cls = self.dyn()->conv.classify(sk, tk)
            match cls {
                case ConvClass::I {
                    self._lint_widening(n, src, target, expected)
                    return target
                } case ConvClass::W {
                    self._lint_widening(n, src, target, expected)
                    return target
                } case ConvClass::E {
                    return target
                } case ConvClass::U {
                    if !self.dyn()->in_unsafe() {
                        self.dyn()->fail(
                            n,
                            DiagID::SC023E,
                            f"cast from '{self.dyn()->tu.str(src)}' to '{self.dyn()->tu.str(target)}' requires an unsafe context",
                        )

                        return &null
                    }

                    return target
                } case ConvClass::X {
                    self.dyn()->sc->diag->report(
                        DiagID::SC027E,
                        n->range.start,
                        f"no conversion from '{self.dyn()->tu.str(src)}' to '{self.dyn()->tu.str(target)}'",
                    ).first(n->range)->note(
                        n->range.start,
                        "these types have no meaningful representation change; use a library function",
                    )->emit()
                    n->poison()
                    return &null
                }
            }
        }

        // T? as T: no collapsing cast.
        if self.dyn()->tu.nullable_inner(src) != &null
            && self.dyn()->tu.strip_nullable(src) == self.dyn()->tu.strip_nullable(target) {
            self.dyn()->sc->diag->report(
                DiagID::SC029E,
                n->range.start,
                f"cannot cast '{self.dyn()->tu.str(src)}' to '{self.dyn()->tu.str(target)}'; a cast cannot fabricate a value for null",
            ).first(n->range)->note(
                n->range.start,
                "use 'x ?? default' to supply a fallback, or 'x!' to assert non-null",
            )->emit()
            n->poison()
            return &null
        }

        // 5b. plain enum <-> exact underlying
        var sed = dyn_cast<EnumDecl>(self.dyn()->tu.record_decl(src))
        var ted = dyn_cast<EnumDecl>(
            self.dyn()->tu.record_decl(self.dyn()->tu.strip_nullable(target)),
        )

        if sed != &null && tk != BuiltinKind::COUNT {
            if sed->is_adt {
                self.dyn()->fail(
                    n,
                    DiagID::SC092E,
                    "ADT enums cannot be cast to integers; expose the tag through an 'extend' method",
                )

                return &null
            }

            var under = self._enum_underlying(sed)
            if under != self.dyn()->tu.strip_nullable(target) {
                self.dyn()->fail(
                    n,
                    DiagID::SC092E,
                    f"'{self.dyn()->tu.decl_name((unsafe (sed as unsafe *Decl)))}' is backed by '{self.dyn()->tu.str(under)}'; cast to that first",
                )

                return &null
            }

            return target
        }

        if ted != &null && sk != BuiltinKind::COUNT {
            if ted->is_adt {
                self.dyn()->fail(n, DiagID::SC092E, "an integer cannot be cast to an ADT enum")
                return &null
            }

            var under = self._enum_underlying(ted)
            // A `const u8` operand is a u8: the qualifier is the variable's,
            // not the value's.
            if under != canon_unqual(src) {
                var en = self.dyn()->tu.decl_name(ted)
                if ted->is_imported() {
                    self.dyn()->fail(
                        n,
                        DiagID::SC092E,
                        f"'{en}' is backed by '{self.dyn()->tu.str(under)}'; the source must have exactly that type",
                    )

                    return &null
                }

                // A Kairo enum: the one place a value could be truncated on
                // the way in is its own, visible cast to the underlying type.
                var u = self.dyn()->tu.str(under)
                var b = self.dyn()->sc->diag->report(
                    DiagID::SC127E,
                    n->range.start,
                    f"casting '{self.dyn()->tu.str(src)}' to '{en}' needs its underlying type '{u}'; cast to '{u}' first",
                )

                b.first(n->range)
                if n->operand != &null {
                    var _op = self.dyn()->sc->ctx->get_spelling(n->operand->range)
                    b.fix(n->operand->range, f"({_op} as {u})", f"cast to '{u}' first")
                }

                b.emit()
                n->poison()
                return &null
            }

            if !ted->is_open {
                // The values are written as StmtTyping walks the enum: one
                // declared below this cast has none yet (run() checks it).
                if self._enum_values_known(ted) {
                    self.check_closed_enum_cast(n, ted)
                } else {
                    self.dyn()->defer_enum_cast(n)
                }
            }

            return target
        }

        // 5b'. `[T; N] as [T;]`: the view an implicit site takes, written out.
        if self.dyn()->conv.array_views_as(src, canon_unqual(target)) {
            return target
        }

        // 5b''. a function as a `fn` value, written out: a named function is
        //       its raw `unsafe fn` pointer and widens to the `fn` value of
        //       its signature implicitly (type-system.mdx), as does a `fn`
        //       into a wider panic effect. The cast is that same conversion,
        //       so it is the implicit rule's verdict and EmitIR lowers it as
        //       the implicit site does (_value). Without this rung the one
        //       explicit spelling of an accepted conversion was SC027E.
        var tfn = canon_unqual(self.dyn()->tu.strip_nullable(target))
        if tfn != &null
            && isa<FunctionPointerType>(tfn)
            && isa<FunctionPointerType>(canon_unqual(src))
            && self.dyn()->conv.implicit(src, target) != ImplicitRank::None {
            self._lint_widening(n, src, target, expected)
            return target
        }

        // 5b'''. `T? as U?` where the implicit rules convert it (`*D? as
        //        *B?`, `*B? as *const B?`): the same conversion written out,
        //        lowered as the implicit site is (EmitIR::_nullable_convert).
        //        Without it the explicit spelling was SC027E.
        if self.dyn()->tu.nullable_inner(src) != &null
            && self.dyn()->tu.nullable_inner(target) != &null
            && self.dyn()->conv.implicit(src, target) != ImplicitRank::None {
            self._lint_widening(n, src, target, expected)
            return target
        }

        // 5c. `fn op as (self) -> T` on the source
        //     A bounds-checked parameter's `op as` is its bounds' (Compiler/Spec/Generics.md
        //     D0): looked up in them, and absent there is the error below,
        //     never a conversion C++ might find per instance.
        var cands  = cxx::std::vector<*Decl>()
        var cg     = self.dyn()->tu.checked_head(src)
        var cbound = Substitution(self.dyn()->sc).bound_ifaces(src)
        if cg != &null {
            for var i: usize = 0; i < cbound.size(); ++i {
                self.dyn()->ml.lookup(
                    cbound[i],
                    DeclName::op_name(TokenKind::KwAs, TokenKind::TkUnknown),
                    &cands,
                )
            }
        } else {
            self.dyn()->ml.lookup(
                self.dyn()->tu.strip_nullable(src),
                DeclName::op_name(TokenKind::KwAs, TokenKind::TkUnknown),
                &cands,
            )
        }

        if cands.size() > 0 {
            var exact = cxx::std::vector<*Decl>()
            for var i: usize = 0; i < cands.size(); ++i {
                var *f? = dyn_cast<FunctionDecl>(cands[i])
                if f == &null {
                    continue
                }

                var rt = self.dyn()->fn_return_type(f)
                // A generic record's `op as -> T`: the target is T as the
                // source instance binds it (`Wrap<i64> as i64`). Unbound
                // (a bound's requirement, a dependent source) keeps `rt`.
                if rt != &null && rt->is_dependent() && cg == &null {
                    var sb = Substitution(self.dyn()->sc)
                    sb.bind_from_record(self.dyn()->tu.strip_nullable(src))
                    var srt = sb.substitute(rt)
                    if srt != &null {
                        rt = srt
                    }
                }

                if rt != &null && rt == self.dyn()->tu.strip_nullable(target) {
                    exact.push_back(cands[i])
                }
            }

            if exact.size() > 0 {
                var args = cxx::std::vector<ArgInfo>()
                var r    = self.dyn()->ovl.resolve(&exact, &args, true, n->range, "op as", src)
                if r.outcome == OvlOutcome::Dependent {
                    self.dyn()->mark_unknown(n)
                    return &null
                }

                if r.outcome != OvlOutcome::Selected {
                    self.dyn()->poison_only(n)
                    return &null
                }

                n->resolved_op = r.decl
                n->op_via_free = r.via_free
                return target
            }
        }

        // 5d. a converting constructor on the target
        var td2 = self.dyn()->tu.record_decl(self.dyn()->tu.strip_nullable(target))
        if td2 != &null {
            var body = self.dyn()->sc->body_of(td2) // a partial spec's ctors for an instance it was selected for.
            var dc   = NameLookup::context_of(body)
            if dc != &null {
                var cell = self.dyn()->sc->lookup.in_context(dc, DeclName::ctor())
                if cell.found() {
                    var ctors = cxx::std::vector<*Decl>()
                    for var i: usize = 0; i < cell.cell->size(); ++i {
                        var f = dyn_cast<FunctionDecl>(cell.cell->get(i))
                        // A @copy/@move ctor takes the target itself: never a
                        // conversion from another type, and on a dependent
                        // source it would turn 5e's bound diagnostic into a
                        // bare "no matching overload".
                        if f == &null || f->transfer != TransferKind::NotTransfer {
                            continue
                        }

                        // exactly one non-self parameter, and not C++ `explicit`:
                        // this rung IS the converting-constructor rule, and
                        // `explicit` is a header's own statement that a ctor
                        // is not a conversion.
                        var nreal: usize       = 0
                        var only:  *ParamDecl? = &null
                        for var j: usize = 0; j < f->params.size(); ++j {
                            if f->params[j] != &null && !f->params[j]->is_self {
                                nreal += 1
                                only = f->params[j]
                            }
                        }

                        // A bounds-checked source (`T as string`, T a
                        // generic parameter) converts only through what its
                        // bounds declare: a constructor whose parameter is a
                        // concrete type (string's `*const u8`) can never take
                        // it, and trying it would turn 5e's bound diagnostic
                        // into a bare "no matching overload".
                        if cg != &null
                            && only != &null
                            && only->type_ != &null
                            && only->type_->canonical != &null
                            && !only->type_->canonical->is_dependent() {
                            continue
                        }

                        if nreal == 1 && !f->ffi_explicit {
                            ctors.push_back(cell.cell->get(i))
                        }
                    }

                    if ctors.size() > 0 {
                        var args = cxx::std::vector<ArgInfo>()
                        args.push_back(self.dyn()->arg_info(n->operand))
                        var r = self.dyn()->ovl.resolve(
                            &ctors,
                            &args,
                            true,
                            n->range,
                            self.dyn()->tu.decl_name(td2),
                        )

                        if r.outcome == OvlOutcome::Dependent {
                            self.dyn()->mark_unknown(n)
                            return &null
                        }

                        if r.outcome != OvlOutcome::Selected {
                            self.dyn()->poison_only(n)
                            return &null
                        }

                        // resolved_op stays NULL on this rung: a constructor
                        // has no op_token to spell. resolved_ctor carries the
                        // choice, and OperatorLowering turns the cast into the
                        // construction it is.
                        n->resolved_ctor = r.decl
                        r.ded.bind_from_record(self.dyn()->tu.strip_nullable(target))
                        self.dyn()->finish_call_args(r.decl, &args, &r)
                        return target
                    }
                }
            }
        }

        // 5e. nothing
        if cg != &null {
            self.dyn()->needs_bound(
                n,
                cg,
                cbound.size() > 0,
                f"'as {self.dyn()->tu.str(target)}' on '{self.dyn()->tu.head_spelling(src)}' needs a bound that declares 'op as' returning '{self.dyn()->tu.str(target)}'",
            )

            return &null
        }

        self.dyn()->fail(
            n,
            DiagID::SC027E,
            f"no conversion from '{self.dyn()->tu.str(src)}' to '{self.dyn()->tu.str(target)}'",
        )

        return &null
    }

    /// Every variant of \p en has its value written (StmtTyping), or the
    /// enum has no variants at all.
    priv fn _enum_values_known(self, en: *EnumDecl) -> bool {
        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v == &null || !v->value.ok {
                return false
            }
        }

        return true
    }

    /// The closed plain enum the cast \p n targets (through a `?`), or null.
    fn closed_enum_of(self, n: unsafe *TypeCastExpr) -> unsafe *EnumDecl {
        if n == &null || n->type_ == &null {
            return &null
        }

        var ted = dyn_cast<EnumDecl>(
            self.dyn()->tu.record_decl(self.dyn()->tu.strip_nullable(n->type_)),
        )

        if ted == &null || ted->is_adt || ted->is_open {
            return &null
        }

        return ted
    }

    /// `v as E` into closed plain enum \p en: a constant \p n's operand
    /// must be one of E's values (SC001E otherwise); anything else is
    /// checked at run time (TypeCastExpr::enum_check). A variant whose own
    /// value failed already said so, and the cast says nothing more.
    fn check_closed_enum_cast(self, n: unsafe *TypeCastExpr, en: unsafe *EnumDecl) {
        if n == &null || en == &null || n->is_poisoned() || n->operand == &null {
            return
        }

        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v == &null || !v->value.ok {
                return
            }
        }

        var ce = ConstEval(self.dyn()->sc)
        var c  = ce.eval_int(n->operand)
        if !c.ok || c.overflow {
            n->enum_check = en
            return
        }

        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v->value.neg == c.neg && v->value.mag == c.mag {
                return
            }
        }

        var unsafe *d  = unsafe (en as unsafe *Decl)
        var        nm  = self.dyn()->tu.decl_name(d)
        var        u   = self.dyn()->tu.str(self._enum_underlying(en))
        var        val = ce.str(c)
        var b = self.dyn()->sc->diag->report(
            DiagID::SC252E,
            n->range.start,
            f"{val} is not a value of '{nm}': a closed enum holds only its variants' values",
        )

        b.first(n->operand->range, f"this is {val}")
        b.note(
            en->range.start,
            f"'{nm}' is declared here; it is closed, so a value no variant has is an error",
        )

        if !self.dyn()->tu.is_foreign(d) {
            b.insert(en->range.start, "@open ", f"declare '{nm}' '@open' to let it hold any '{u}'")
        }

        b.emit()
        n->poison()
    }

    priv fn _enum_underlying(self, e: unsafe *EnumDecl) -> unsafe *Type {
        if e->underlying != &null && e->underlying->canonical != &null {
            return e->underlying->canonical
        }

        return self.dyn()->tu.builtin(BuiltinKind::U32) // documented default.
    }

    /// Two pointers of one safety whose chains meet on one canonical once
    /// every level's cv is stripped: the only thing a cast between them can
    /// change is qualifiers.
    /// Pointee \p tp is a bare generic parameter X that every instance makes
    /// a class derived from record pointee \p sp: one of X's `derives`
    /// bounds is \p sp or reaches it (`X derives Stmts<X>` with `Stmts<T>
    /// derives Rav<T>` casts a `*Rav<X>` down too). A `: type` X is C++'s to
    /// check (Compiler/Spec/Generics.md#duck-regime): the static_cast is written as is and clang
    /// rejects an instance whose X is not derived from the base, at that
    /// instance, never as a reinterpret. Nothing else relates a parameter
    /// to a record, so every other pointee stays SC091E.
    priv fn _bound_downcast(self, sp: unsafe *Type, tp: unsafe *Type) -> bool {
        var unsafe *g = dyn_cast<GenericParamType>(canon_unqual(tp))
        if g == &null || g->is_pack || g->owner == &null {
            return false
        }

        var gps = decl_generic_params(g->owner)
        if (g->param_index as usize) >= gps.size() {
            return false
        }

        var unsafe *gp = gps[g->param_index as usize]
        if gp == &null {
            return false
        }

        if gp->kind_bound == GenericParamKindBound::Duck {
            return true
        }

        var unsafe *src = canon_unqual(sp)
        var        bs   = self.dyn()->tu.bound_bases(tp)
        for var i: usize = 0; i < bs.size(); ++i {
            if Substitution(self.dyn()->sc).derives_from(bs[i], src) {
                return true
            }
        }

        return false
    }

    priv fn _same_pointer_shape(self, a: unsafe *Type, b: unsafe *Type) -> bool {
        var unsafe *au = canon_unqual(a)
        var unsafe *bu = canon_unqual(b)
        var        ap  = self.dyn()->tu.pointee(au)
        var        bp  = self.dyn()->tu.pointee(bu)
        if ap == &null || bp == &null {
            return false
        }

        if self.dyn()->tu.is_unsafe_ptr(au) != self.dyn()->tu.is_unsafe_ptr(bu) {
            return false
        }

        var apu = canon_unqual(ap)
        var bpu = canon_unqual(bp)
        if apu == bpu {
            return true
        }

        return self._same_pointer_shape(apu, bpu)
    }

    /// First pointee level (outermost first) where \p target lost a
    /// qualifier \p src had, or &null. Walks the shape _same_pointer_shape
    /// already proved.
    priv fn _dropped_at(self, src: unsafe *Type, target: unsafe *Type) -> unsafe *Type {
        var sp = self.dyn()->tu.pointee(canon_unqual(src))
        var tp = self.dyn()->tu.pointee(canon_unqual(target))
        if sp == &null || tp == &null {
            return &null
        }

        if (canon_quals(sp) & ~canon_quals(tp)) != 0 {
            return sp
        }

        return self._dropped_at(sp, tp)
    }

    /// A pointer cast that only moves qualifiers but is not [conv.qual]:
    /// either a level lost one, or one was added below a level that is not
    /// `const` (the `**T -> **const T` hole).
    priv fn _qual_cast_error(self,
                             n:      unsafe *TypeCastExpr,
                             src:    unsafe *Type,
                             target: unsafe *Type) {
        var unsafe *lost = self._dropped_at(src, target)
        if lost != &null {
            var what = if (canon_has_const(lost)) => ("const") else => "volatile"
            self.dyn()->sc->diag->report(
                DiagID::SC030E,
                n->range.start,
                f"cast from '{self.dyn()->tu.str(src)}' to '{self.dyn()->tu.str(target)}' drops '{what}' from the pointee '{self.dyn()->tu.str(lost)}'",
            ).first(n->range)->note(
                n->range.start,
                "'as' can add 'const' to a pointee, never remove it, and cannot add it on one level while removing it on another; that is a reinterpret: 'as unsafe *T' inside an 'unsafe' block",
            )->emit()
            n->poison()
            return
        }

        self.dyn()->sc->diag->report(
            DiagID::SC030E,
            n->range.start,
            f"cast from '{self.dyn()->tu.str(src)}' to '{self.dyn()->tu.str(target)}' adds 'const' below a pointer that is not 'const'",
        ).first(n->range)->note(
            n->range.start,
            "the result could store a '*const T' through a '*T'; make every level above the added 'const' 'const' too",
        )->emit()
        n->poison()
    }

    /// A widening cast is redundant only where the value lands in a slot
    /// that already takes the SOURCE: `f(x as u32)` into a u32 parameter,
    /// `var y: u32 = x as u32`, `return x as u32`. \p expected is that
    /// slot. Anywhere else the cast is doing work the implicit rule would
    /// not: `var y = x as u32` picks y's type, and in `(b as u16) << 8`
    /// it picks the width the shift runs at -- without it a u8 shift loses
    /// the high byte. Operator operands arrive with no expected type (see
    /// cast_operand_expected), so those never lint.
    priv fn _lint_widening(self,
                           n:        *TypeCastExpr,
                           src:      *Type,
                           target:   unsafe *Type,
                           expected: unsafe *Type) {
        n->widening = true
        if expected == &null {
            return
        }

        if self.dyn()->conv.implicit(src, expected) == ImplicitRank::None {
            return
        }

        self._lint_redundant(n, src, target)
    }

    /// The redundant-cast lint for a slot whose type arrives after the cast
    /// was typed: a call argument, whose parameter is known only once
    /// overload resolution has run (arguments are typed with no expected
    /// type, so type_cast could not decide it). Same test as _lint_widening.
    ///
    /// \p overloaded: the callee had other candidates, or the slot deduces
    /// its type from the argument. The cast may be what selected this one
    /// (`f(x as u64)` beside `f(u32)`) or what T deduced, and removing it
    /// would pick another, so neither ever lints.
    fn lint_cast_into_slot(self, e: *Expr, slot: unsafe *Type, overloaded: bool) {
        if slot == &null || overloaded {
            return
        }

        var n = dyn_cast<TypeCastExpr>(self.dyn()->tu.strip_parens(e))
        if n == &null || !n->widening || n->is_poisoned() {
            return
        }

        var src = n->operand->type_
        if src == &null {
            return
        }

        // A literal cast is redundant only into a slot of exactly its type
        // (see type_cast's same-type rung).
        // And only a bare literal adapts to a parameter: an if/else or a
        // binary operator over literals is typed before the call is
        // resolved, so without the cast it is an i32 the callee refuses.
        if self._is_literal_shape(n->operand) {
            if !self._is_plain_literal(n->operand) || canon_unqual(slot) != canon_unqual(n->type_) {
                return
            }
        }

        if self.dyn()->conv.implicit(src, slot) == ImplicitRank::None {
            return
        }

        self._lint_redundant(n, src, n->type_)
    }

    /// SC253W on `p as *D`: it crashes on a miss, and the
    /// checked `p as *D?` lets the caller decide. The edit appends the `?`
    /// (`*D?` is `(*D)?`, Compiler/Spec/Nullables.md#the-pointer-suffix).
    priv fn _warn_asserting_downcast(self, n: *TypeCastExpr, td: *Decl) {
        var cast_text = self.dyn()->sc->ctx->get_spelling(n->range)
        var dn        = self.dyn()->tu.decl_name(td)
        var b = self.dyn()->sc->diag->report(
            DiagID::SC253W,
            n->range.start,
            f"'{cast_text}' crashes the program when the object is not a '{dn}'; use '{cast_text}?' and test the result for cleaner handling",
        )

        b.first(n->range, "asserting downcast")
        b.note(td->range.start, f"'{dn}' is declared here")
        b.insert(n->range.end, "?", "make it the checked downcast, null on a miss")
        b.emit()
    }

    /// Whether \p e is a literal, through parens, a prefix operator
    /// (`-1`, `&null`), an if/else or a binary operator over literals: the
    /// operands whose type the cast decides.
    priv fn _is_literal_shape(self, e: unsafe *Expr) -> bool {
        var unsafe *s = self.dyn()->tu.strip_parens(e)
        if isa<IntegerLiteralExpr>(s)
            || isa<FloatingLiteralExpr>(s)
            || isa<CharacterLiteralExpr>(s)
            || isa<BooleanLiteralExpr>(s)
            || isa<NullLiteralExpr>(s) {
            return true
        }

        var u = dyn_cast<UnaryOperatorExpr>(s)
        if u != &null {
            return self._is_literal_shape(u->operand)
        }

        // `(if c => 1 else => 2) as u32` and `(1 << 3) as u64`: literals all
        // the way down take the cast's type just the same.
        var ie = dyn_cast<IfExpr>(s)
        if ie != &null {
            return self._is_literal_shape(ie->then_expr) && self._is_literal_shape(ie->else_expr)
        }

        var be = dyn_cast<BinaryOperatorExpr>(s)
        if be != &null {
            return self._is_literal_shape(be->lhs) && self._is_literal_shape(be->rhs)
        }

        return false
    }

    /// A literal, through parens and prefix operators only.
    priv fn _is_plain_literal(self, e: *Expr) -> bool {
        var unsafe *s = self.dyn()->tu.strip_parens(e)
        if isa<IntegerLiteralExpr>(s)
            || isa<FloatingLiteralExpr>(s)
            || isa<CharacterLiteralExpr>(s)
            || isa<BooleanLiteralExpr>(s)
            || isa<NullLiteralExpr>(s) {
            return true
        }

        var u = dyn_cast<UnaryOperatorExpr>(s)
        if u != &null {
            return self._is_plain_literal(u->operand)
        }

        return false
    }

    priv fn _lint_redundant(self, n: *TypeCastExpr, src: *Type, target: unsafe *Type) {
        // `0xFFFFFFFF as char` is not redundant against a char slot: the
        // implicit literal path range-checks, the cast does not. The same for
        // byte: `0x1FF as byte` truncates where `var b: byte = 0x1FF` is an error.
        if (self.dyn()->tu.is_builtin(canon_unqual(target), BuiltinKind::Char)
            || self.dyn()->tu.is_builtin(canon_unqual(target), BuiltinKind::Byte))
            && isa<IntegerLiteralExpr>(self.dyn()->tu.strip_parens(n->operand)) {
            return
        }

        var b = self.dyn()->sc->diag->report(
            DiagID::SC031W,
            n->range.start,
            f"redundant cast: '{self.dyn()->tu.str(src)}' converts to '{self.dyn()->tu.str(target)}' implicitly",
        )

        b.first(n->range)
        // The edit is the ` as T` and nothing else. It is read off the source
        // text between the cast's start and its target type rather than the
        // operand's range, which leaves out the operand's own parentheses and
        // so cannot say where the operand ends.
        if n->target != &null {
            var head = self.dyn()->sc->ctx->get_spelling(
                SourceRange::from_bounds(n->range.start, n->target->range.start),
            )

            var e = head.length()
            while e > 0 && self._is_blank(head[e - 1]) {
                e -= 1
            }

            if e >= 3 && head[e - 1] == 115 && head[e - 2] == 97 && self._is_blank(head[e - 3]) {
                e -= 2
                while e > 0 && self._is_blank(head[e - 1]) {
                    e -= 1
                }

                b.remove(
                    SourceRange::from_bounds(n->range.start.advance(e), n->range.end),
                    "remove the cast",
                )
            }
        }

        b.emit()
    }

    priv fn _is_blank(self, c: u8) -> bool {
        return c == 32 || c == 9 || c == 10 || c == 13
    }
}
