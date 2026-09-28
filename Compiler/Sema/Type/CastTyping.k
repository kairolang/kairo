/// --- The Kairo Project ---------------------- Sema/Type/CastTyping.k --- ///
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
///                                            downcast: ASSERTING, panic site,
///                                            S must be polymorphic
///       4. target is `*X?`, same relation    checked downcast, null on miss
///       5. static ladder: lattice I/W (lint) / E / U / X -> plain enum <->
///          exact underlying -> `op as` on the source -> one-param ctor on
///          the target -> error.  `op as` beats ctor.
///
///     `as static T` runs the ladder with 3-4 disabled and errors when the
///     answer would have been dynamic; a static downcast is forbidden
///     outright (it is a reinterpret wearing a hat). `as const T` asserts 1.
///     `T? as T` is an error naming `??` / `!`; there is no collapsing cast.
///
///     Pointer <-> integer: `ptr as usize` needs no unsafe; `ptr as u8` is an
///     error, not a warning; `int as unsafe *T` needs unsafe; `int as *T` is
///     an error; `*T as unsafe *T` needs unsafe.
///
///     Which of the four the source wrote is `TypeCastExpr::mode`; the
///     parser leaves `const` / `unsafe` in the target's qualifiers too, so
///     the const rung can compare the WRITTEN type and `as unsafe *T` lands
///     on the `unsafe *T` canonical rather than on `*T` plus a bit.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Resolve::NameLookup::*;
import Sema::Type::TypeUtil::*;
import Sema::Type::Conversion::*;
import Sema::Type::OverloadResolution::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;

class <T> CastTyping {
    priv inline fn dyn(self) -> *T { return static_cast::<*T>(&self); }

    fn type_cast(self, n: *TypeCastExpr, expected: *Type) -> *Type {
        if (n->target == &null) || n->target->is_poisoned() {
            dyn()->type_of(n->operand, &null);
            dyn()->poison_only(n);
            return &null;
        }
        var target = n->target->canonical;
        if target == &null {
            dyn()->type_of(n->operand, &null);
            dyn()->mark_unknown(n);   // dependent target: M2.
            return &null;
        }

        var mode = n->mode;
        var target_unsafe_ptr = (mode == CastMode::Unsafe) || dyn()->tu.is_unsafe_ptr(target);

        // The literal-takes-the-type rule applies through a cast too: `10 as u8`
        // is a u8 literal, not an i32 narrowed.
        var src = dyn()->type_of(n->operand, target);
        if dyn()->propagate(n, n->operand) { return &null; }
        if src == &null { return &null; }
        if src == target {
            self._lint_redundant(n, src, target);
            return target;
        }

        // 1. const cast, one-way: the target is the operand's own type with
        //    qualifiers added. Read off the canonicals: `as const T` is
        //    qualified(CONST, T) against a T.
        if (canon_unqual(target) == canon_unqual(src))
        && ((canon_quals(src) & (~canon_quals(target))) == 0) { return target; }

        // 1b. the same, one level down: `*T as *const T`. The top-level
        //     rung above only sees the pointer's own cv, so without this a
        //     pointee qualifier fell through to the record rung and read as
        //     "unrelated types". Adding follows [conv.qual]; dropping at any
        //     level -- including a drop hidden beside an addition at another
        //     level -- is not a const cast and stays behind `as unsafe *`.
        if (!dyn()->tu.is_unsafe_ptr(target)) && (mode != CastMode::Unsafe) && self._same_pointer_shape(src, target) {
            if dyn()->conv.qualification(src, target) { return target; }
            self._qual_cast_error(n, src, target);
            return &null;
        }
        if mode == CastMode::Const {
            dyn()->fail(n, f"'as const' only adds qualifiers: '{dyn()->tu.str(target)}' is not '{dyn()->tu.str(src)}' with 'const' added");
            return &null;
        }

        // 2. reinterpret to `unsafe *X`.
        if target_unsafe_ptr && (dyn()->tu.pointee(target) != &null) {
            if (dyn()->tu.pointee(src) == &null) && (!dyn()->tu.is_integer(src)) {
                dyn()->fail(n, f"only a pointer or an integer can be cast to '{dyn()->tu.str(target)}'; '{dyn()->tu.str(src)}' is neither");
                return &null;
            }
            if !dyn()->in_unsafe() {
                dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                    f"cast to '{dyn()->tu.str(target)}' requires an unsafe context"
                ).first(n->range)
                 .note(n->range.start, "wrap the expression in 'unsafe { ... }'; this cast discards pointer provenance")
                 .emit();
                n->poison();
                return &null;
            }
            return target;
        }

        // 3 / 4. pointer casts between related records.
        var sp = dyn()->tu.pointee(src);
        var tp = dyn()->tu.pointee(dyn()->tu.strip_nullable(target));
        if (sp != &null) && (tp != &null) {
            if dyn()->tu.is_unsafe_ptr(src) {
                dyn()->fail(n, f"cannot cast the unsafe pointer '{dyn()->tu.str(src)}' to a safe pointer; that is a checked construction, not a cast");
                return &null;
            }
            var sd = dyn()->tu.record_decl(sp);
            var td = dyn()->tu.record_decl(tp);
            var to_nullable = dyn()->tu.nullable_inner(target) != &null;
            if (sd == &null) || (td == &null) {
                if dyn()->tu.is_void(tp) {
                    dyn()->fail(n, f"cannot cast '{dyn()->tu.str(src)}' to the safe pointer '{dyn()->tu.str(target)}'; erasing the pointee type needs 'as unsafe *void' inside an 'unsafe' block");
                    return &null;
                }
                dyn()->fail(n, f"pointer cast between unrelated types '{dyn()->tu.str(src)}' and '{dyn()->tu.str(target)}'; use 'as unsafe *' to reinterpret");
                return &null;
            }
            if dyn()->tu.derives_from(sd, td) {
                // upcast: static, implicit already does it.
                self._lint_widening(n, src, target, expected);
                return target;
            }
            if dyn()->tu.derives_from(td, sd) {
                if mode == CastMode::Static {
                    dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                        f"static downcast from '{dyn()->tu.str(src)}' to '{dyn()->tu.str(target)}' is not allowed"
                    ).first(n->range)
                     .note(n->range.start, "write 'as *X' for a checked cast that panics, 'as *X?' for one that yields null, or 'as unsafe *X' to reinterpret")
                     .emit();
                    n->poison();
                    return &null;
                }
                if !dyn()->tu.is_polymorphic(sd) {
                    dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                        f"cannot downcast from '{dyn()->tu.str(src)}': '{dyn()->tu.decl_name(sd)}' has no virtual methods, so there is no runtime type to check"
                    ).first(n->range)
                     .note(sd->range.start, "declared here").first(sd->range)
                     .emit();
                    n->poison();
                    return &null;
                }
                if !to_nullable {
                    dyn()->note_panic_site(static_cast::<*Expr>(n));   // PanicEffectChecking reads it.
                }
                return target;
            }
            dyn()->fail(n, f"'{dyn()->tu.decl_name(sd)}' and '{dyn()->tu.decl_name(td)}' are unrelated; use 'as unsafe *' to reinterpret");
            return &null;
        }

        // pointer -> integer, integer -> pointer
        if (sp != &null) && dyn()->tu.is_integer(target) {
            if dyn()->tu.kind_of(target) != BuiltinKind::USize {
                dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                    f"a pointer converts to 'usize' only; write 'as usize as {dyn()->tu.str(target)}' if you mean to narrow the address"
                ).first(n->range).emit();
                n->poison();
                return &null;
            }
            return target;
        }
        if (tp != &null) && dyn()->tu.is_integer(src) {
            dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                f"cannot cast the integer type '{dyn()->tu.str(src)}' to the safe pointer '{dyn()->tu.str(target)}'; only 'as unsafe *T' can turn an integer into an address"
            ).first(n->range).emit();
            n->poison();
            return &null;
        }

        // 5. the static ladder.
        // 5a. lattice
        var sk = dyn()->tu.kind_of(src);
        var tk = dyn()->tu.kind_of(dyn()->tu.strip_nullable(target));
        if (sk != BuiltinKind::COUNT) && (tk != BuiltinKind::COUNT) {
            var cls = dyn()->conv.classify(sk, tk);
            switch cls {
                case ConvClass::I { self._lint_widening(n, src, target, expected); return target; }
                case ConvClass::W { self._lint_widening(n, src, target, expected); return target; }
                case ConvClass::E { return target; }
                case ConvClass::U {
                    if !dyn()->in_unsafe() { dyn()->fail(n, f"cast from '{dyn()->tu.str(src)}' to '{dyn()->tu.str(target)}' requires an unsafe context"); return &null; }
                    return target;
                }
                case ConvClass::X {
                    dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                        f"no conversion from '{dyn()->tu.str(src)}' to '{dyn()->tu.str(target)}\x27"
                    ).first(n->range)
                     .note(n->range.start, "these types have no meaningful representation change; use a library function")
                     .emit();
                    n->poison();
                    return &null;
                }
            }
        }

        // T? as T: no collapsing cast.
        if (dyn()->tu.nullable_inner(src) != &null) && (dyn()->tu.strip_nullable(src) == dyn()->tu.strip_nullable(target)) {
            dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                f"cannot cast '{dyn()->tu.str(src)}' to '{dyn()->tu.str(target)}'; a cast cannot fabricate a value for null"
            ).first(n->range)
             .note(n->range.start, "use 'x ?? default' to supply a fallback, or 'x!' to assert non-null")
             .emit();
            n->poison();
            return &null;
        }

        // 5b. plain enum <-> exact underlying
        var sed = dyn_cast::<EnumDecl>(dyn()->tu.record_decl(src));
        var ted = dyn_cast::<EnumDecl>(dyn()->tu.record_decl(dyn()->tu.strip_nullable(target)));
        if (sed != &null) && (tk != BuiltinKind::COUNT) {
            if sed->is_adt { dyn()->fail(n, "ADT enums cannot be cast to integers; expose the tag through an 'extend' method"); return &null; }
            var under = self._enum_underlying(sed);
            if under != dyn()->tu.strip_nullable(target) {
                dyn()->fail(n, f"'{dyn()->tu.decl_name(static_cast::<*Decl>(sed))}' is backed by '{dyn()->tu.str(under)}'; cast to that first");
                return &null;
            }
            return target;
        }
        if (ted != &null) && (sk != BuiltinKind::COUNT) {
            if ted->is_adt { dyn()->fail(n, "an integer cannot be cast to an ADT enum"); return &null; }
            var under = self._enum_underlying(ted);
            if under != src {
                dyn()->fail(n, f"'{dyn()->tu.decl_name(static_cast::<*Decl>(ted))}' is backed by '{dyn()->tu.str(under)}'; the source must have exactly that type");
                return &null;
            }
            return target;
        }

        // 5c. `fn op as (self) -> T` on the source
        var cands = vec::<*Decl>();
        dyn()->ml.lookup(dyn()->tu.strip_nullable(src), DeclName::op_name(TokenKind::KwAs, TokenKind::TkUnknown), &cands);
        if cands.size() > 0 {
            var exact = vec::<*Decl>();
            for var i: usize = 0; i < cands.size(); ++i {
                var f = dyn_cast::<FunctionDecl>(cands[i]);
                if f == &null { continue; }
                var rt = dyn()->fn_return_type(f);
                if (rt != &null) && (rt == dyn()->tu.strip_nullable(target)) { exact.push_back(cands[i]); }
            }
            if exact.size() > 0 {
                var args = vec::<ArgInfo>();
                var r = dyn()->ovl.resolve(&exact, &args, true, n->range, "op as", src);
                if r.outcome == OvlOutcome::Dependent { dyn()->mark_unknown(n); return &null; }
                if r.outcome != OvlOutcome::Selected { dyn()->poison_only(n); return &null; }
                n->resolved_op = r.decl;
                n->op_via_free = r.via_free;
                return target;
            }
        }

        // 5d. a converting constructor on the target
        var td2 = dyn()->tu.record_decl(dyn()->tu.strip_nullable(target));
        if td2 != &null {
            var body = dyn()->tu.pattern_of(td2);
            var dc   = NameLookup::context_of(body);
            if dc != &null {
                var cell = dyn()->sc->lookup.in_context(dc, DeclName::ctor());
                if cell.found() {
                    var ctors = vec::<*Decl>();
                    for var i: usize = 0; i < cell.cell->size(); ++i {
                        var f = dyn_cast::<FunctionDecl>(cell.cell->get(i));
                        if f == &null { continue; }
                        // exactly one non-self parameter, and not C++ `explicit`:
                        // this rung IS the converting-constructor rule, and
                        // `explicit` is a header's own statement that a ctor
                        // is not a conversion.
                        var nreal: usize = 0;
                        for var j: usize = 0; j < f->params.size(); ++j {
                            if (f->params[j] != &null) && (!f->params[j]->is_self) { nreal += 1; }
                        }
                        if (nreal == 1) && (!f->ffi_explicit) { ctors.push_back(cell.cell->get(i)); }
                    }
                    if ctors.size() > 0 {
                        var args = vec::<ArgInfo>();
                        args.push_back(dyn()->arg_info(n->operand));
                        var r = dyn()->ovl.resolve(&ctors, &args, true, n->range, dyn()->tu.decl_name(td2));
                        if r.outcome == OvlOutcome::Dependent { dyn()->mark_unknown(n); return &null; }
                        if r.outcome != OvlOutcome::Selected { dyn()->poison_only(n); return &null; }
                        // resolved_op stays NULL on this rung: a constructor
                        // has no op_token to spell. resolved_ctor carries the
                        // choice, and OperatorLowering turns the cast into the
                        // construction it is.
                        n->resolved_ctor = r.decl;
                        r.ded.bind_from_record(dyn()->tu.strip_nullable(target));
                        dyn()->finish_call_args(r.decl, &args, &r);
                        return target;
                    }
                }
            }
        }

        // 5e. nothing
        dyn()->fail(n, f"no conversion from '{dyn()->tu.str(src)}' to '{dyn()->tu.str(target)}\x27");
        return &null;
    }

    priv fn _enum_underlying(self, e: *EnumDecl) -> *Type {
        if (e->underlying != &null) && (e->underlying->canonical != &null) { return e->underlying->canonical; }
        return dyn()->tu.builtin(BuiltinKind::U32);   // documented default.
    }

    /// Two pointers of one safety whose chains meet on one canonical once
    /// every level's cv is stripped: the only thing a cast between them can
    /// change is qualifiers.
    priv fn _same_pointer_shape(self, a: *Type, b: *Type) -> bool {
        var au = canon_unqual(a);
        var bu = canon_unqual(b);
        var ap = dyn()->tu.pointee(au);
        var bp = dyn()->tu.pointee(bu);
        if (ap == &null) || (bp == &null) { return false; }
        if dyn()->tu.is_unsafe_ptr(au) != dyn()->tu.is_unsafe_ptr(bu) { return false; }
        var apu = canon_unqual(ap);
        var bpu = canon_unqual(bp);
        if apu == bpu { return true; }
        return self._same_pointer_shape(apu, bpu);
    }

    /// First pointee level (outermost first) where \p target lost a
    /// qualifier \p src had, or &null. Walks the shape _same_pointer_shape
    /// already proved.
    priv fn _dropped_at(self, src: *Type, target: *Type) -> *Type {
        var sp = dyn()->tu.pointee(canon_unqual(src));
        var tp = dyn()->tu.pointee(canon_unqual(target));
        if (sp == &null) || (tp == &null) { return &null; }
        if (canon_quals(sp) & (~canon_quals(tp))) != 0 { return sp; }
        return self._dropped_at(sp, tp);
    }

    /// A pointer cast that only moves qualifiers but is not [conv.qual]:
    /// either a level lost one, or one was added below a level that is not
    /// `const` (the `**T -> **const T` hole).
    priv fn _qual_cast_error(self, n: *TypeCastExpr, src: *Type, target: *Type) {
        var lost = self._dropped_at(src, target);
        if lost != &null {
            var what = ("const") if (canon_has_const(lost)) else ("volatile");
            dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                f"cast from '{dyn()->tu.str(src)}' to '{dyn()->tu.str(target)}' drops '{what}' from the pointee '{dyn()->tu.str(lost)}\x27"
            ).first(n->range)
             .note(n->range.start, "'as' can add 'const' to a pointee, never remove it, and cannot add it on one level while removing it on another; that is a reinterpret: 'as unsafe *T' inside an 'unsafe' block")
             .emit();
            n->poison();
            return;
        }
        dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
            f"cast from '{dyn()->tu.str(src)}' to '{dyn()->tu.str(target)}' adds 'const' below a pointer that is not 'const\x27"
        ).first(n->range)
         .note(n->range.start, "the result could store a '*const T' through a '*T'; make every level above the added 'const' 'const' too")
         .emit();
        n->poison();
    }

    /// A widening cast is redundant only where the value lands in a slot
    /// that already takes the SOURCE: `f(x as u32)` into a u32 parameter,
    /// `var y: u32 = x as u32`, `return x as u32`. \p expected is that
    /// slot. Anywhere else the cast is doing work the implicit rule would
    /// not: `var y = x as u32` picks y's type, and in `(b as u16) << 8`
    /// it picks the width the shift runs at -- without it a u8 shift loses
    /// the high byte. Operator operands arrive with no expected type (see
    /// cast_operand_expected), so those never lint.
    priv fn _lint_widening(self, n: *TypeCastExpr, src: *Type, target: *Type, expected: *Type) {
        n->widening = true;
        if expected == &null { return; }
        if dyn()->conv.implicit(src, expected) == ImplicitRank::None { return; }
        self._lint_redundant(n, src, target);
    }

    /// The redundant-cast lint for a slot whose type arrives after the cast
    /// was typed: a call argument, whose parameter is known only once
    /// overload resolution has run (arguments are typed with no expected
    /// type, so type_cast could not decide it). Same test as _lint_widening.
    fn lint_cast_into_slot(self, e: *Expr, slot: *Type) {
        if slot == &null { return; }
        var n = dyn_cast::<TypeCastExpr>(dyn()->tu.strip_parens(e));
        if (n == &null) || (!n->widening) || n->is_poisoned() { return; }
        var src = n->operand->type_;
        if src == &null { return; }
        if dyn()->conv.implicit(src, slot) == ImplicitRank::None { return; }
        self._lint_redundant(n, src, n->type_);
    }

    priv fn _lint_redundant(self, n: *TypeCastExpr, src: *Type, target: *Type) {
        dyn()->sc->diag->report(DiagID::SC001W, n->range.start,
            f"redundant cast: '{dyn()->tu.str(src)}' converts to '{dyn()->tu.str(target)}' implicitly"
        ).first(n->range).emit();
    }
}