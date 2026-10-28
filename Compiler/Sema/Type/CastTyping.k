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
///     operand is checked here: a miss is SC001E (placeholder) with a fix-it
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Resolve::NameLookup::*;
import Sema::Type::TypeUtil::*;
import Sema::Type::Conversion::*;
import Sema::Type::Substitution::*;
import Sema::Type::OverloadResolution::*;
import Sema::Check::ConstEval::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
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
        // is a u8 literal, not an i32 narrowed. Into a plain enum the literal
        // takes the enum's underlying type, the one rung 5b accepts: `3 as
        // Color` is the u8 3, so a closed enum can check it as a constant.
        var op_expected = target;
        var ped = dyn_cast::<EnumDecl>(dyn()->tu.record_decl(dyn()->tu.strip_nullable(target)));
        if (ped != &null) && (!ped->is_adt) && (!ped->is_imported()) { op_expected = self._enum_underlying(ped); }
        var src = dyn()->type_of(n->operand, op_expected);
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
            dyn()->fail(n, DiagID::SC030E, f"'as const' only adds qualifiers: '{dyn()->tu.str(target)}' is not '{dyn()->tu.str(src)}' with 'const' added");
            return &null;
        }

        // 2. reinterpret to `unsafe *X`.
        if target_unsafe_ptr && (dyn()->tu.pointee(target) != &null) {
            if (dyn()->tu.pointee(src) == &null) && (!dyn()->tu.is_integer(src)) {
                dyn()->fail(n, DiagID::SC026E, f"only a pointer or an integer can be cast to '{dyn()->tu.str(target)}'; '{dyn()->tu.str(src)}' is neither");
                return &null;
            }
            if !dyn()->in_unsafe() {
                dyn()->sc->diag->report(DiagID::SC023E, n->range.start,
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
                // raw -> safe: the mirror of `as unsafe *T`, and the only way
                // memory born raw (every C allocation) becomes a safe pointer.
                // The `unsafe` block is the programmer's claim that the
                // pointer is valid; this cast is what the claim is about.
                // When AMT can adopt a pointer, the adoption hooks this
                // spelling -- the checked construction gets a new lowering,
                // not a new syntax. Same pointee only, cv kept by the rule-1b
                // test: retyping or dropping `const` is still `as unsafe *`.
                var raw_twin = dyn()->sc->types->pointer(tp, true);
                if !self._same_pointer_shape(src, raw_twin) {
                    dyn()->fail(n, DiagID::SC091E, f"cannot cast '{dyn()->tu.str(src)}' to '{dyn()->tu.str(target)}': a raw pointer becomes safe only with its own pointee; reinterpret with 'as unsafe *' first");
                    return &null;
                }
                if !dyn()->conv.qualification(src, raw_twin) {
                    self._qual_cast_error(n, src, target);
                    return &null;
                }
                if !dyn()->in_unsafe() {
                    dyn()->sc->diag->report(DiagID::SC023E, n->range.start,
                        f"cast from the raw pointer '{dyn()->tu.str(src)}' to the safe pointer '{dyn()->tu.str(target)}' requires an unsafe context"
                    ).first(n->range)
                     .note(n->range.start, "wrap it in 'unsafe { ... }': the block is your claim that the pointer is valid")
                     .emit();
                    n->poison();
                    return &null;
                }
                return target;
            }
            var sd = dyn()->tu.record_decl(sp);
            var td = dyn()->tu.record_decl(tp);
            var to_nullable = dyn()->tu.nullable_inner(target) != &null;
            if (sd == &null) || (td == &null) {
                // A pointee that is a generic parameter: which classes meet is
                // the instance's question. The checked form is a dynamic_cast
                // either way, which C++ checks per instance (an upcast or the
                // same class passes, an unrelated or non-polymorphic downcast
                // is its error there).
                if to_nullable && (sp->is_dependent() || tp->is_dependent()) {
                    n->checked_downcast = true;
                    return target;
                }
                // 3b. the CRTP downcast: `&self as *X` in a base whose X is
                //     bounded `derives Mixin<X>`. The bound proves every X
                //     is a Mixin<X>, so the target is known statically and
                //     the cast is C++'s static_cast (EmitIR's default kind),
                //     with no vtable and no `unsafe`. A reinterpret there is
                //     wrong, not just unsafe: a mixin that is not the first
                //     base sits at a nonzero offset.
                if (!to_nullable) && (sd != &null) && self._bound_downcast(sp, tp) {
                    if (canon_quals(sp) & (~canon_quals(tp))) != 0 {
                        self._qual_cast_error(n, src, target);
                        return &null;
                    }
                    return target;
                }
                if dyn()->tu.is_void(tp) {
                    dyn()->fail(n, DiagID::SC091E, f"cannot cast '{dyn()->tu.str(src)}' to the safe pointer '{dyn()->tu.str(target)}'; erasing the pointee type needs 'as unsafe *void' inside an 'unsafe' block");
                    return &null;
                }
                dyn()->fail(n, DiagID::SC091E, f"pointer cast between unrelated types '{dyn()->tu.str(src)}' and '{dyn()->tu.str(target)}'; use 'as unsafe *' to reinterpret");
                return &null;
            }
            if Substitution(dyn()->sc).derives_from(sp, tp) {
                // upcast: static, implicit already does it.
                self._lint_widening(n, src, target, expected);
                return target;
            }
            if Substitution(dyn()->sc).derives_from(tp, sp) {
                if mode == CastMode::Static {
                    dyn()->sc->diag->report(DiagID::SC024E, n->range.start,
                        f"static downcast from '{dyn()->tu.str(src)}' to '{dyn()->tu.str(target)}' is not allowed"
                    ).first(n->range)
                     .note(n->range.start, "write 'as *X' for a checked cast that crashes on a miss, 'as *X?' for one that yields null, or 'as unsafe *X' to reinterpret")
                     .emit();
                    n->poison();
                    return &null;
                }
                if !dyn()->tu.is_polymorphic(sd) {
                    dyn()->sc->diag->report(DiagID::SC025E, n->range.start,
                        f"cannot downcast from '{dyn()->tu.str(src)}': '{dyn()->tu.decl_name(sd)}' has no virtual methods, so there is no runtime type to check"
                    ).first(n->range)
                     .note(sd->range.start, "declared here").first(sd->range)
                     .emit();
                    n->poison();
                    return &null;
                }
                if !to_nullable {
                    dyn()->note_panic_site(static_cast::<*Expr>(n));   // PanicEffectChecking reads it.
                    // PANIC.md §5: a miss CRASHES (OperatorLowering builds the
                    // check), joins no panic set, and always warns: the
                    // checked form says what to do on a miss instead.
                    n->asserting_downcast = true;
                    self._warn_asserting_downcast(n, td);
                } else {
                    n->checked_downcast = true;
                }
                return target;
            }
            dyn()->fail(n, DiagID::SC091E, f"'{dyn()->tu.decl_name(sd)}' and '{dyn()->tu.decl_name(td)}' are unrelated; use 'as unsafe *' to reinterpret");
            return &null;
        }

        // pointer -> integer, integer -> pointer
        if (sp != &null) && dyn()->tu.is_integer(target) {
            if dyn()->tu.kind_of(target) != BuiltinKind::USize {
                // Every other integer is refused, u64 and isize included:
                // usize is the one type that holds an address on every
                // target, and the two-step spelling is the honest one.
                var ts = dyn()->tu.str(target);
                var b = dyn()->sc->diag->report(DiagID::SC026E, n->range.start,
                    f"a pointer converts to 'usize' only; write 'as usize as {ts}' if you mean to narrow the address");
                b.first(n->range, f"pointer cast to '{ts}\x27");
                b.note(n->operand->range.start, f"'{dyn()->tu.str(src)}' is a pointer; its address is a 'usize', and narrowing that is an ordinary integer cast");
                if (n->target != &null) && n->target->range.is_valid() {
                    b.insert(n->target->range.start, "usize as ", "read the address as 'usize' first");
                }
                b.emit();
                n->poison();
                return &null;
            }
            return target;
        }
        if (tp != &null) && dyn()->tu.is_integer(src) {
            dyn()->sc->diag->report(DiagID::SC026E, n->range.start,
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
                    if !dyn()->in_unsafe() { dyn()->fail(n, DiagID::SC023E, f"cast from '{dyn()->tu.str(src)}' to '{dyn()->tu.str(target)}' requires an unsafe context"); return &null; }
                    return target;
                }
                case ConvClass::X {
                    dyn()->sc->diag->report(DiagID::SC027E, n->range.start,
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
            dyn()->sc->diag->report(DiagID::SC029E, n->range.start,
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
            if sed->is_adt { dyn()->fail(n, DiagID::SC092E, "ADT enums cannot be cast to integers; expose the tag through an 'extend' method"); return &null; }
            var under = self._enum_underlying(sed);
            if under != dyn()->tu.strip_nullable(target) {
                dyn()->fail(n, DiagID::SC092E, f"'{dyn()->tu.decl_name(static_cast::<*Decl>(sed))}' is backed by '{dyn()->tu.str(under)}'; cast to that first");
                return &null;
            }
            return target;
        }
        if (ted != &null) && (sk != BuiltinKind::COUNT) {
            if ted->is_adt { dyn()->fail(n, DiagID::SC092E, "an integer cannot be cast to an ADT enum"); return &null; }
            var under = self._enum_underlying(ted);
            // A `const u8` operand is a u8: the qualifier is the variable's,
            // not the value's.
            if under != canon_unqual(src) {
                var en = dyn()->tu.decl_name(static_cast::<*Decl>(ted));
                if ted->is_imported() {
                    dyn()->fail(n, DiagID::SC092E, f"'{en}' is backed by '{dyn()->tu.str(under)}'; the source must have exactly that type");
                    return &null;
                }
                // A Kairo enum: the one place a value could be truncated on
                // the way in is its own, visible cast to the underlying type.
                var u = dyn()->tu.str(under);
                var b = dyn()->sc->diag->report(DiagID::SC127E, n->range.start,
                    f"casting '{dyn()->tu.str(src)}' to '{en}' needs its underlying type '{u}'; cast to '{u}' first"
                );
                b.first(n->range);
                if n->operand != &null {
                    var _op = dyn()->sc->ctx->get_spelling(n->operand->range);
                    b.fix(n->operand->range, f"({_op} as {u})", f"cast to '{u}' first");
                }
                b.emit();
                n->poison();
                return &null;
            }
            if !ted->is_open {
                // The values are written as StmtTyping walks the enum: one
                // declared below this cast has none yet (run() checks it).
                if self._enum_values_known(ted) { self.check_closed_enum_cast(n, ted); }
                else { dyn()->defer_enum_cast(n); }
            }
            return target;
        }

        // 5b'. `[T; N] as [T;]`: the view an implicit site takes, written out.
        if dyn()->conv.array_views_as(src, canon_unqual(target)) { return target; }

        // 5c. `fn op as (self) -> T` on the source
        //     A bounds-checked parameter's `op as` is its bounds' (MONO.md
        //     D0): looked up in them, and absent there is the error below,
        //     never a conversion C++ might find per instance.
        var cands = vec::<*Decl>();
        var cg = dyn()->tu.checked_param(src);
        var cbound = dyn()->tu.bound_ifaces(src);
        if cg != &null {
            for var i: usize = 0; i < cbound.size(); ++i {
                dyn()->ml.lookup(cbound[i], DeclName::op_name(TokenKind::KwAs, TokenKind::TkUnknown), &cands);
            }
        } else {
            dyn()->ml.lookup(dyn()->tu.strip_nullable(src), DeclName::op_name(TokenKind::KwAs, TokenKind::TkUnknown), &cands);
        }
        if cands.size() > 0 {
            var exact = vec::<*Decl>();
            for var i: usize = 0; i < cands.size(); ++i {
                var f = dyn_cast::<FunctionDecl>(cands[i]);
                if f == &null { continue; }
                var rt = dyn()->fn_return_type(f);
                // A generic record's `op as -> T`: the target is T as the
                // source instance binds it (`Wrap<i64> as i64`). Unbound
                // (a bound's requirement, a dependent source) keeps `rt`.
                if (rt != &null) && rt->is_dependent() && (cg == &null) {
                    var sb = Substitution(dyn()->sc);
                    sb.bind_from_record(dyn()->tu.strip_nullable(src));
                    var srt = sb.substitute(rt);
                    if srt != &null { rt = srt; }
                }
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
            var body = dyn()->sc->body_of(td2);   // a partial spec's ctors for an instance it was selected for.
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
        if cg != &null {
            dyn()->needs_bound(static_cast::<*Expr>(n), cg, cbound.size() > 0,
                f"'as {dyn()->tu.str(target)}' on '{dyn()->sc->ctx->get_spelling(cg->name)}' needs a bound that declares 'op as' returning '{dyn()->tu.str(target)}\x27");
            return &null;
        }
        dyn()->fail(n, DiagID::SC027E, f"no conversion from '{dyn()->tu.str(src)}' to '{dyn()->tu.str(target)}\x27");
        return &null;
    }

    /// Every variant of \p en has its value written (StmtTyping), or the
    /// enum has no variants at all.
    priv fn _enum_values_known(self, en: *EnumDecl) -> bool {
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if (v == &null) || (!v->value.ok) { return false; }
        }
        return true;
    }

    /// The closed plain enum the cast \p n targets (through a `?`), or null.
    fn closed_enum_of(self, n: *TypeCastExpr) -> *EnumDecl {
        if (n == &null) || (n->type_ == &null) { return &null; }
        var ted = dyn_cast::<EnumDecl>(dyn()->tu.record_decl(dyn()->tu.strip_nullable(n->type_)));
        if (ted == &null) || ted->is_adt || ted->is_open { return &null; }
        return ted;
    }

    /// `v as E` into closed plain enum \p en: a constant \p n's operand
    /// must be one of E's values (SC001E otherwise); anything else is
    /// checked at run time (TypeCastExpr::enum_check). A variant whose own
    /// value failed already said so, and the cast says nothing more.
    fn check_closed_enum_cast(self, n: *TypeCastExpr, en: *EnumDecl) {
        if (n == &null) || (en == &null) || n->is_poisoned() || (n->operand == &null) { return; }
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if (v == &null) || (!v->value.ok) { return; }
        }
        var ce = ConstEval(dyn()->sc);
        var c  = ce.eval_int(n->operand);
        if (!c.ok) || c.overflow {
            n->enum_check = static_cast::<*Decl>(en);
            return;
        }
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if (v->value.neg == c.neg) && (v->value.mag == c.mag) { return; }
        }
        var d   = static_cast::<*Decl>(en);
        var nm  = dyn()->tu.decl_name(d);
        var u   = dyn()->tu.str(self._enum_underlying(en));
        var val = ce.str(c);
        var b = dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
            f"{val} is not a value of '{nm}': a closed enum holds only its variants\x27 values");
        b.first(n->operand->range, f"this is {val}");
        b.note(en->range.start, f"'{nm}' is declared here; it is closed, so a value no variant has is an error");
        if !dyn()->tu.is_foreign(d) {
            b.insert(en->range.start, "@open ", f"declare '{nm}' '@open' to let it hold any '{u}\x27");
        }
        b.emit();
        n->poison();
    }

    priv fn _enum_underlying(self, e: *EnumDecl) -> *Type {
        if (e->underlying != &null) && (e->underlying->canonical != &null) { return e->underlying->canonical; }
        return dyn()->tu.builtin(BuiltinKind::U32);   // documented default.
    }

    /// Two pointers of one safety whose chains meet on one canonical once
    /// every level's cv is stripped: the only thing a cast between them can
    /// change is qualifiers.
    /// Pointee \p tp is a bare generic parameter X that every instance makes
    /// a class derived from record pointee \p sp: one of X's `derives`
    /// bounds is \p sp or reaches it (`X derives Stmts<X>` with `Stmts<T>
    /// derives Rav<T>` casts a `*Rav<X>` down too). A `: type` X is C++'s to
    /// check (MONO.md D1): the static_cast is written as is and clang
    /// rejects an instance whose X is not derived from the base, at that
    /// instance, never as a reinterpret. Nothing else relates a parameter
    /// to a record, so every other pointee stays SC091E.
    priv fn _bound_downcast(self, sp: *Type, tp: *Type) -> bool {
        var g = dyn_cast::<GenericParamType>(canon_unqual(tp));
        if (g == &null) || g->is_pack || (g->owner == &null) { return false; }
        var gps = decl_generic_params(g->owner);
        if static_cast::<usize>(g->param_index) >= gps.size() { return false; }
        var gp = gps[static_cast::<usize>(g->param_index)];
        if gp == &null { return false; }
        if gp->kind_bound == GenericParamKindBound::Duck { return true; }
        var src = canon_unqual(sp);
        var bs = dyn()->tu.bound_bases(tp);
        for var i: usize = 0; i < bs.size(); ++i {
            if Substitution(dyn()->sc).derives_from(bs[i], src) { return true; }
        }
        return false;
    }

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
            dyn()->sc->diag->report(DiagID::SC030E, n->range.start,
                f"cast from '{dyn()->tu.str(src)}' to '{dyn()->tu.str(target)}' drops '{what}' from the pointee '{dyn()->tu.str(lost)}\x27"
            ).first(n->range)
             .note(n->range.start, "'as' can add 'const' to a pointee, never remove it, and cannot add it on one level while removing it on another; that is a reinterpret: 'as unsafe *T' inside an 'unsafe' block")
             .emit();
            n->poison();
            return;
        }
        dyn()->sc->diag->report(DiagID::SC030E, n->range.start,
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

    /// SC001W (placeholder) on `p as *D`: it crashes on a miss, and the
    /// checked `p as *D?` lets the caller decide. The edit appends the `?`
    /// (`*D?` is `(*D)?`, NULLABLE.md G1).
    priv fn _warn_asserting_downcast(self, n: *TypeCastExpr, td: *Decl) {
        var cast_text = dyn()->sc->ctx->get_spelling(n->range);
        var dn = dyn()->tu.decl_name(td);
        var b = dyn()->sc->diag->report(DiagID::SC001W, n->range.start,
            f"'{cast_text}' crashes the program when the object is not a '{dn}'; use '{cast_text}?' and test the result for cleaner handling");
        b.first(n->range, "asserting downcast");
        b.note(td->range.start, f"'{dn}' is declared here");
        b.insert(n->range.end, "?", "make it the checked downcast, null on a miss");
        b.emit();
    }

    priv fn _lint_redundant(self, n: *TypeCastExpr, src: *Type, target: *Type) {
        dyn()->sc->diag->report(DiagID::SC031W, n->range.start,
            f"redundant cast: '{dyn()->tu.str(src)}' converts to '{dyn()->tu.str(target)}' implicitly"
        ).first(n->range).emit();
    }
}