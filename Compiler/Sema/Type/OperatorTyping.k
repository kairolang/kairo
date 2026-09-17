/// --- The Kairo Project ------------------ Sema/Type/OperatorTyping.k --- ///
///
///   \brief Unary, binary and assignment operators. Builtin operands follow
///          the lattice's §6 unification; anything else is a user operator
///          found by member lookup under its op_name key and resolved as a
///          call with the left operand as receiver.
///
///   \detail
///     §6, verbatim: for operands A != B, if W(A->B) and not W(B->A) the
///     operand type is B; the mirror gives A; otherwise error. There is no
///     "usual arithmetic conversion" and `u32 + i32` is an error on purpose.
///     Comparison uses the same unification and yields bool; shifts unify the
///     right operand independently; compound assignment converts the right
///     operand only.
///
///     An untyped literal on one side takes the other side's type (§5), which
///     is why `x + 1` works for any integer x with no conversion at all.
///
///     User operators: the left operand's members and extensions
///     (MemberLookup) under `DeclName::op_name(k0, k1)`, PLUS free operator
///     functions found by ADL in the modules of either operand's type
///     (MemberLookup::associated_scopes). Members take the left operand as
///     receiver; frees take every operand as an argument. Both rank in one
///     set (OverloadResolution::resolve_mixed), so a member and a free
///     function at the same rank are ambiguous, as in C++.
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
import Sema::Type::TypeUtil::*;
import Sema::Type::Conversion::*;
import Sema::Type::OverloadResolution::*;
import AST::Context::SymbolTable::*;
import AST::Context::DeclContext::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import Token::Token::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;

class <T> OperatorTyping {
    priv inline fn dyn(self) -> *T { return static_cast::<*T>(&self); }

    // === classification of the operator token ===============================

    priv fn _is_arith(self, k: TokenKind) -> bool {
        return (k == TokenKind::OpPlus) || (k == TokenKind::OpMinus) || (k == TokenKind::OpStar)
            || (k == TokenKind::OpSlash) || (k == TokenKind::OpPercent) || (k == TokenKind::OpCaretCaret);
    }
    priv fn _is_bitwise(self, k: TokenKind) -> bool {
        return (k == TokenKind::OpAmp) || (k == TokenKind::OpPipe) || (k == TokenKind::OpCaret)
            || (k == TokenKind::KwBitand) || (k == TokenKind::KwBitor) || (k == TokenKind::KwXor);
    }
    priv fn _is_shift(self, k: TokenKind) -> bool {
        return (k == TokenKind::OpLessLess) || (k == TokenKind::OpGreaterGreater);
    }
    priv fn _is_logical(self, k: TokenKind) -> bool {
        return (k == TokenKind::OpAmpAmp) || (k == TokenKind::OpPipePipe)
            || (k == TokenKind::KwAnd) || (k == TokenKind::KwOr);
    }
    priv fn _is_equality(self, k: TokenKind) -> bool {
        return (k == TokenKind::OpEqualEqual) || (k == TokenKind::OpExclaimEqual)
            || (k == TokenKind::KwNotEq);
    }
    priv fn _is_relational(self, k: TokenKind) -> bool {
        return (k == TokenKind::OpLess) || (k == TokenKind::OpGreater)
            || (k == TokenKind::OpLessEqual) || (k == TokenKind::OpGreaterEqual);
    }

    /// §6 unification, or null. Operands are read as values; their
    /// top-level cv is gone by the time they meet.
    fn unify_operands(self, a_in: *Type, b_in: *Type) -> *Type {
        if (a_in == &null) || (b_in == &null) { return &null; }
        var a = canon_unqual(a_in);
        var b = canon_unqual(b_in);
        if a == b { return a; }
        var ab = dyn()->conv.implicit(a, b);
        var ba = dyn()->conv.implicit(b, a);
        if (ab != ImplicitRank::None) && (ba == ImplicitRank::None) { return b; }
        if (ba != ImplicitRank::None) && (ab == ImplicitRank::None) { return a; }
        return &null;
    }

    // === user operators =====================================================

    /// Try `lhs_ty`'s `op <k>` members. Returns the result type, null when no
    /// operator exists (caller falls back to builtins / errors). Diagnoses
    /// only when candidates existed and resolution failed.
    fn user_binary(self, n: *Expr, k0: TokenKind, k1: TokenKind, lhs: *Expr, lhs_ty: *Type,
                   rhs: *Expr, found: *bool) -> *Type {
        (*found) = false;
        if lhs_ty == &null { return &null; }
        var name  = DeclName::op_name(k0, k1);
        var cands = vec::<*Decl>();
        dyn()->ml.lookup(dyn()->tu.strip_nullable(lhs_ty), name, &cands);

        var margs = vec::<ArgInfo>();
        if rhs != &null { margs.push_back(dyn()->arg_info(rhs)); }

        // ADL over BOTH operands: `std::cout << p` finds `std::op <<` through
        // the left, `2 * v` finds `vecmath::op *` through the right.
        var scopes = vec::<*DeclContext>();
        dyn()->ml.associated_scopes(lhs_ty, &scopes);
        if margs.size() > 0 { dyn()->ml.associated_scopes(margs[0].ty, &scopes); }
        var frees = vec::<*Decl>();
        dyn()->ml.adl_candidates(&scopes, name, "", &cands, &frees);
        if (cands.size() == 0) && (frees.size() == 0) { return &null; }
        (*found) = true;

        var fargs = self._free_args(lhs, &margs);
        var spelled = dyn()->sc->ctx->get_spelling(cast::<BinaryOperatorExpr>(n)->op_token);
        var r = dyn()->ovl.resolve_mixed(&cands, &margs, true, &frees, &fargs, n->range, f"op {spelled}");
        if r.outcome == OvlOutcome::Dependent { dyn()->mark_unknown(n); return &null; }
        if r.outcome != OvlOutcome::Selected { dyn()->poison_only(n); return &null; }
        // Record what was chosen. OperatorLowering rewrites the node from this
        // and never looks an operator up again.
        var bin = cast::<BinaryOperatorExpr>(n);
        bin->resolved_op = r.decl;
        bin->op_via_free = r.via_free;
        dyn()->finish_call_args(r.decl, (&fargs) if (r.via_free) else (&margs), &r);
        return dyn()->call_result_type(r.decl, &r);
    }

    /// A free operator's argument list: the receiver operand first, then what
    /// a member would have taken.
    priv fn _free_args(self, recv: *Expr, margs: *vec::<ArgInfo>) -> vec::<ArgInfo> {
        var out = vec::<ArgInfo>();
        out.push_back(dyn()->arg_info(recv));
        for var i: usize = 0; i < margs->size(); ++i { out.push_back((*margs)[i]); }
        return out;
    }

    // === binary =============================================================

    fn type_binary(self, n: *BinaryOperatorExpr, expected: *Type) -> *Type {
        var k = n->op_token.kind;

        // literal on one side takes the other's type.
        var l_lit = dyn()->is_untyped_literal(n->lhs);
        var r_lit = dyn()->is_untyped_literal(n->rhs);
        var lt: *Type = &null;
        var rt: *Type = &null;
        var numeric_ctx = self._is_arith(k) || self._is_bitwise(k) || self._is_equality(k) || self._is_relational(k);
        var pass_down: *Type = (expected) if (self._is_arith(k) || self._is_bitwise(k)) else (&null);

        if l_lit && (!r_lit) {
            rt = dyn()->type_of(n->rhs, pass_down);
            lt = dyn()->type_of(n->lhs, (rt) if (numeric_ctx) else (pass_down));
        } else if r_lit && (!l_lit) {
            lt = dyn()->type_of(n->lhs, pass_down);
            rt = dyn()->type_of(n->rhs, (lt) if (numeric_ctx) else (pass_down));
        } else {
            lt = dyn()->type_of(n->lhs, pass_down);
            rt = dyn()->type_of(n->rhs, (lt) if (numeric_ctx && (pass_down == &null)) else (pass_down));
        }
        if dyn()->propagate(n, n->lhs) || dyn()->propagate(n, n->rhs) { return &null; }
        if (lt == &null) || (rt == &null) { return &null; }
        // Every builtin result below is a prvalue, and user_binary is safe to
        // hand the stripped type: ml.lookup and ADL both peel it anyway.
        lt = canon_unqual(lt);
        rt = canon_unqual(rt);

        // A DEPENDENT operand has no operator table yet: which `op +` applies
        // to `T` is decided by the instantiation, not here. Rejecting it at
        // definition time would make every generic that adds ill-formed, so
        // the answer is deferred (M2) rather than diagnosed.
        if self._is_dependent(lt) || self._is_dependent(rt) {
            dyn()->mark_unknown(n);
            return &null;
        }

        // `??`
        if k == TokenKind::OpQuestionQuestion {
            var inner = dyn()->tu.nullable_inner(lt);
            if inner == &null {
                dyn()->warn(n, f"left operand of '??' has non-nullable type '{dyn()->tu.str(lt)}'; the right operand is never used");
                return lt;
            }
            var j = dyn()->conv.join(inner, dyn()->tu.strip_nullable(rt));
            if j == &null {
                dyn()->fail(n, f"'??' operands '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}' have no common type");
                return &null;
            }
            // T? ?? U?  stays nullable; T? ?? U collapses.
            return (dyn()->sc->types->nullable(j)) if (dyn()->tu.nullable_inner(rt) != &null) else (j);
        }

        // `===`: identity. Pointers, nullables of pointers, or the same record.
        if k == TokenKind::OpEqualEqualEqual {
            if self.unify_operands(lt, rt) == &null {
                dyn()->fail(n, f"'===' operands '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}' are unrelated");
                return &null;
            }
            return dyn()->tu.builtin(BuiltinKind::Bool);
        }

        // user operator on a record / extended type.
        var lb = dyn()->tu.kind_of(lt) != BuiltinKind::COUNT;
        var rb = dyn()->tu.kind_of(rt) != BuiltinKind::COUNT;
        if !(lb && rb) {
            var found = false;
            var ut = self.user_binary(static_cast::<*Expr>(n), k, TokenKind::TkUnknown, n->lhs, lt, n->rhs, &found);
            if found { return ut; }
            // no user operator: only equality on identical types is builtin for non-primitives.
            if self._is_equality(k) && (self.unify_operands(lt, rt) != &null) {
                return dyn()->tu.builtin(BuiltinKind::Bool);
            }
            dyn()->fail(n, f"no operator '{dyn()->sc->ctx->get_spelling(n->op_token)}' for operands '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}\x27");
            return &null;
        }

        // builtins
        if self._is_logical(k) {
            if (!dyn()->tu.is_bool(lt)) || (!dyn()->tu.is_bool(rt)) {
                dyn()->fail(n, "logical operators require 'bool' operands; use a comparison or an explicit cast");
                return &null;
            }
            return dyn()->tu.builtin(BuiltinKind::Bool);
        }
        if self._is_shift(k) {
            if (!dyn()->tu.is_integer(lt)) || (!dyn()->tu.is_integer(rt)) {
                dyn()->fail(n, "shift operands must be integers");
                return &null;
            }
            return lt;
        }
        if self._is_bitwise(k) {
            if dyn()->tu.is_bool(lt) && dyn()->tu.is_bool(rt) { return lt; }
            if dyn()->tu.is_builtin(lt, BuiltinKind::Byte) && dyn()->tu.is_builtin(rt, BuiltinKind::Byte) { return lt; }
            if dyn()->tu.is_integer(lt) && dyn()->tu.is_integer(rt) {
                var u = self.unify_operands(lt, rt);
                if u == &null { self._unify_error(n, lt, rt); return &null; }
                return u;
            }
            dyn()->fail(n, f"bitwise operators require two integers, two bytes, or two bools, not '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}\x27");
            return &null;
        }
        if self._is_arith(k) {
            if (!dyn()->tu.is_numeric(lt)) || (!dyn()->tu.is_numeric(rt)) {
                dyn()->fail(n, f"arithmetic requires numeric operands, not '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}\x27");
                return &null;
            }
            var u = self.unify_operands(lt, rt);
            if u == &null { self._unify_error(n, lt, rt); return &null; }
            return u;
        }
        if self._is_equality(k) || self._is_relational(k) {
            if self._is_relational(k) && (!(dyn()->tu.is_numeric(lt) || dyn()->tu.is_builtin(lt, BuiltinKind::Char))) {
                dyn()->fail(n, f"ordering comparison is not defined on '{dyn()->tu.str(lt)}\x27");
                return &null;
            }
            var u = self.unify_operands(lt, rt);
            if u == &null { self._unify_error(n, lt, rt); return &null; }
            return dyn()->tu.builtin(BuiltinKind::Bool);
        }
        if k == TokenKind::OpLessEqualGreater {
            var u = self.unify_operands(lt, rt);
            if u == &null { self._unify_error(n, lt, rt); return &null; }
            var a = vec::<*Type>();
            var ord = dyn()->tu.lang_record(WellKnownType::Ordering, &a);
            if ord == &null { dyn()->missing_lang_item(n, "Ordering"); return &null; }
            return ord;
        }
        if k == TokenKind::KwIn {
            // `x in xs`: xs's `op in`-style containment is a library question; not builtin.
            dyn()->fail(n, "'in' as a binary operator requires an 'op in' on the right operand's type");
            return &null;
        }
        dyn()->fail(n, f"operator '{dyn()->sc->ctx->get_spelling(n->op_token)}' is not defined on primitives");
        return &null;
    }

    priv fn _unify_error(self, n: *Expr, lt: *Type, rt: *Type) {
        dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
            f"operands '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}' do not unify; neither converts implicitly to the other"
        ).first(n->range)
         .note(n->range.start, "cast one side explicitly with 'as' to choose the result type")
         .emit();
        n->poison();
    }

    // === unary ==============================================================

    fn type_unary(self, n: *UnaryOperatorExpr, expected: *Type) -> *Type {
        var k = n->op_token.kind;

        // `-literal` folds the sign into the fit check.
        if n->is_prefix() && (k == TokenKind::OpMinus) {
            var inner = dyn()->tu.strip_parens(n->operand);
            if (inner != &null) && isa::<IntegerLiteralExpr>(inner) {
                var t = dyn()->type_int_literal(cast::<IntegerLiteralExpr>(inner), expected, true);
                dyn()->finish(inner, t);
                if t == &null { dyn()->poison_only(n); return &null; }
                if (!dyn()->tu.is_signed_int(t)) && (!dyn()->tu.is_float(t)) {
                    dyn()->fail(n, f"cannot negate a literal of unsigned type '{dyn()->tu.str(t)}\x27");
                    return &null;
                }
                return t;
            }
        }

        var ot = dyn()->type_of(n->operand, (expected) if ((k == TokenKind::OpMinus) || (k == TokenKind::OpPlus) || (k == TokenKind::OpTilde)) else (&null));
        if dyn()->propagate(n, n->operand) { return &null; }
        if ot == &null { return &null; }

        // user operator first for non-primitives: members, plus free
        // operators the operand's modules declare (ADL).
        if dyn()->tu.kind_of(ot) == BuiltinKind::COUNT
        && (k != TokenKind::OpAmp) && (k != TokenKind::OpStar) {
            var name  = DeclName::op_name(k, TokenKind::TkUnknown);
            var cands = vec::<*Decl>();
            dyn()->ml.lookup(dyn()->tu.strip_nullable(ot), name, &cands);
            var scopes = vec::<*DeclContext>();
            dyn()->ml.associated_scopes(ot, &scopes);
            var frees = vec::<*Decl>();
            dyn()->ml.adl_candidates(&scopes, name, "", &cands, &frees);
            if (cands.size() > 0) || (frees.size() > 0) {
                var margs = vec::<ArgInfo>();
                var fargs = self._free_args(n->operand, &margs);
                var r = dyn()->ovl.resolve_mixed(&cands, &margs, true, &frees, &fargs, n->range,
                                                 f"op {dyn()->sc->ctx->get_spelling(n->op_token)}");
                if r.outcome == OvlOutcome::Dependent { dyn()->mark_unknown(n); return &null; }
                if r.outcome != OvlOutcome::Selected { dyn()->poison_only(n); return &null; }
                n->resolved_op = r.decl;
                n->op_via_free = r.via_free;
                if r.via_free { dyn()->finish_call_args(r.decl, &fargs, &r); }
                return dyn()->call_result_type(r.decl, &r);
            }
        }

        // Same rule as the binary case: a dependent operand defers. `&x` is
        // the exception -- its result is `*T` whatever T turns out to be, so
        // there is nothing to wait for.
        if (k != TokenKind::OpAmp) && self._is_dependent(ot) {
            dyn()->mark_unknown(n);
            return &null;
        }

        switch k {
            case TokenKind::OpExclaim { return self._unary_bool(n, ot); }
            case TokenKind::KwNot     { return self._unary_bool(n, ot); }
            case TokenKind::OpMinus {
                if dyn()->tu.is_float(ot) || dyn()->tu.is_signed_int(ot) { return canon_unqual(ot); }
                dyn()->fail(n, f"cannot negate a value of type '{dyn()->tu.str(ot)}\x27");
                return &null;
            }
            case TokenKind::OpPlus {
                if dyn()->tu.is_numeric(ot) { return canon_unqual(ot); }
                dyn()->fail(n, f"unary '+' requires a numeric operand, not '{dyn()->tu.str(ot)}\x27");
                return &null;
            }
            case TokenKind::OpTilde { return self._unary_bits(n, ot); }
            case TokenKind::KwCompl { return self._unary_bits(n, ot); }
            case TokenKind::OpAmp {
                if !dyn()->is_lvalue(n->operand) {
                    dyn()->fail(n, "cannot take the address of a temporary");
                    return &null;
                }
                return dyn()->sc->types->pointer(ot, false);
            }
            case TokenKind::OpStar {
                var p = dyn()->tu.pointee(ot);
                if p == &null {
                    if dyn()->tu.nullable_inner(ot) != &null {
                        dyn()->fail(n, f"cannot dereference nullable '{dyn()->tu.str(ot)}'; check for null or use '?.\x27");
                    } else {
                        dyn()->fail(n, f"cannot dereference non-pointer type '{dyn()->tu.str(ot)}\x27");
                    }
                    return &null;
                }
                if dyn()->tu.is_void(p) { dyn()->fail(n, "cannot dereference '*void\x27"); return &null; }
                n->value_category = Expr::ValueCategory::LValue;
                return p;
            }
            case TokenKind::OpPlusPlus   { return self._incdec(n, ot); }
            case TokenKind::OpMinusMinus { return self._incdec(n, ot); }
            case TokenKind::OpEllipsis {
                // postfix `x...`: a pack expansion in expression position.
                dyn()->mark_unknown(n);
                return &null;
            }
            default {
                dyn()->fail(n, f"unary operator '{dyn()->sc->ctx->get_spelling(n->op_token)}' is not defined on '{dyn()->tu.str(ot)}\x27");
                return &null;
            }
        }
    }

    /// Dependent in either sense: a type mentioning a generic parameter, and
    /// one whose ARGUMENTS do. Both mean "not knowable until instantiation".
    priv fn _is_dependent(self, t: *Type) -> bool {
        if t == &null { return false; }
        return t->is_dependent() || t->is_instantiation_dependent();
    }

    priv fn _unary_bool(self, n: *UnaryOperatorExpr, ot: *Type) -> *Type {
        if dyn()->tu.is_bool(ot) { return canon_unqual(ot); }
        dyn()->fail(n, f"'!' requires a 'bool' operand, not '{dyn()->tu.str(ot)}\x27");
        return &null;
    }

    priv fn _unary_bits(self, n: *UnaryOperatorExpr, ot: *Type) -> *Type {
        if dyn()->tu.is_integer(ot) || dyn()->tu.is_builtin(ot, BuiltinKind::Byte) { return canon_unqual(ot); }
        dyn()->fail(n, f"'~' requires an integer or byte operand, not '{dyn()->tu.str(ot)}\x27");
        return &null;
    }

    priv fn _incdec(self, n: *UnaryOperatorExpr, ot: *Type) -> *Type {
        if !dyn()->tu.is_integer(ot) {
            dyn()->fail(n, f"'++'/'--' require an integer operand, not '{dyn()->tu.str(ot)}\x27");
            return &null;
        }
        if !dyn()->is_lvalue(n->operand) {
            dyn()->fail(n, "'++'/'--' require an assignable operand");
            return &null;
        }
        if n->is_prefix() { n->value_category = Expr::ValueCategory::LValue; }
        return ot;
    }

    // === assignment =========================================================

    fn type_assign(self, n: *AssignOperatorExpr, expected: *Type) -> *Type {
        var k  = n->op_token.kind;
        var lt = dyn()->type_of(n->lhs, &null);
        if dyn()->propagate(n, n->lhs) { return &null; }
        if lt == &null { return &null; }

        if !dyn()->is_lvalue(n->lhs) {
            dyn()->fail(n, "left side of assignment is not assignable");
            dyn()->type_of(n->rhs, &null);
            return &null;
        }

        if k == TokenKind::OpEqual {
            dyn()->type_of(n->rhs, lt);
            if dyn()->propagate(n, n->rhs) { return &null; }
            if !dyn()->check_convertible(n->rhs, lt) { dyn()->poison_only(n); return &null; }
            n->value_category = Expr::ValueCategory::LValue;
            return lt;
        }

        // compound: the underlying binary op's rules, converting the RIGHT
        // operand only (§6). Records go through `op +=` etc.
        var base = self._compound_base(k);
        var rt   = dyn()->type_of(n->rhs, lt);
        if dyn()->propagate(n, n->rhs) { return &null; }
        if rt == &null { return &null; }

        // Members of the left side, plus ADL over BOTH sides. A primitive left
        // side with a record on the right still asks: `x += v` can be a free
        // `op +=` from v's module.
        var l_rec = dyn()->tu.kind_of(lt) == BuiltinKind::COUNT;
        var r_rec = dyn()->tu.kind_of(rt) == BuiltinKind::COUNT;
        if l_rec || r_rec {
            var name  = DeclName::op_name(k, TokenKind::TkUnknown);
            var cands = vec::<*Decl>();
            dyn()->ml.lookup(dyn()->tu.strip_nullable(lt), name, &cands);
            var margs = vec::<ArgInfo>();
            margs.push_back(dyn()->arg_info(n->rhs));
            var scopes = vec::<*DeclContext>();
            dyn()->ml.associated_scopes(lt, &scopes);
            dyn()->ml.associated_scopes(rt, &scopes);
            var frees = vec::<*Decl>();
            dyn()->ml.adl_candidates(&scopes, name, "", &cands, &frees);
            var any = (cands.size() > 0) || (frees.size() > 0);
            if l_rec && (!any) {
                dyn()->fail(n, f"no operator '{dyn()->sc->ctx->get_spelling(n->op_token)}' on '{dyn()->tu.str(lt)}\x27");
                return &null;
            }
            if any {
                var fargs = self._free_args(n->lhs, &margs);
                var r = dyn()->ovl.resolve_mixed(&cands, &margs, true, &frees, &fargs, n->range,
                                                 f"op {dyn()->sc->ctx->get_spelling(n->op_token)}");
                if r.outcome == OvlOutcome::Dependent { dyn()->mark_unknown(n); return &null; }
                if r.outcome != OvlOutcome::Selected { dyn()->poison_only(n); return &null; }
                n->resolved_op = r.decl;
                n->op_via_free = r.via_free;
                dyn()->finish_call_args(r.decl, (&fargs) if (r.via_free) else (&margs), &r);
                n->value_category = Expr::ValueCategory::LValue;
                return lt;
            }
            // Primitive left, record right, no operator for the pair: the
            // builtin checks below say what is wrong with it.
        }

        if self._is_shift(base) {
            if (!dyn()->tu.is_integer(lt)) || (!dyn()->tu.is_integer(rt)) {
                dyn()->fail(n, "shift-assignment operands must be integers"); return &null;
            }
        } else if self._is_bitwise(base) {
            var ok = (dyn()->tu.is_integer(lt) && dyn()->tu.is_integer(rt))
                  || (dyn()->tu.is_bool(lt) && dyn()->tu.is_bool(rt))
                  || (dyn()->tu.is_builtin(lt, BuiltinKind::Byte) && dyn()->tu.is_builtin(rt, BuiltinKind::Byte));
            if !ok { dyn()->fail(n, f"bitwise assignment is not defined for '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}\x27"); return &null; }
            if !dyn()->check_convertible(n->rhs, lt) { dyn()->poison_only(n); return &null; }
        } else {
            if (!dyn()->tu.is_numeric(lt)) || (!dyn()->tu.is_numeric(rt)) {
                dyn()->fail(n, f"arithmetic assignment is not defined for '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}\x27"); return &null;
            }
            if !dyn()->check_convertible(n->rhs, lt) { dyn()->poison_only(n); return &null; }
        }
        n->value_category = Expr::ValueCategory::LValue;
        return lt;
    }

    priv fn _compound_base(self, k: TokenKind) -> TokenKind {
        switch k {
            case TokenKind::OpPlusEqual           { return TokenKind::OpPlus; }
            case TokenKind::OpMinusEqual          { return TokenKind::OpMinus; }
            case TokenKind::OpStarEqual           { return TokenKind::OpStar; }
            case TokenKind::OpSlashEqual          { return TokenKind::OpSlash; }
            case TokenKind::OpPercentEqual        { return TokenKind::OpPercent; }
            case TokenKind::OpAmpEqual            { return TokenKind::OpAmp; }
            case TokenKind::OpPipeEqual           { return TokenKind::OpPipe; }
            case TokenKind::OpCaretEqual          { return TokenKind::OpCaret; }
            case TokenKind::OpLessLessEqual       { return TokenKind::OpLessLess; }
            case TokenKind::OpGreaterGreaterEqual { return TokenKind::OpGreaterGreater; }
            case TokenKind::KwAndEq               { return TokenKind::OpAmp; }
            case TokenKind::KwOrEq                { return TokenKind::OpPipe; }
            case TokenKind::KwXorEq               { return TokenKind::OpCaret; }
            default                               { return k; }
        }
    }
}