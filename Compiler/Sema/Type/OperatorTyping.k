/// --- The Kairo Project ------------------ Sema/Type/OperatorTyping.k --- ///
///
///   \brief Unary, binary and assignment operators. Builtin operands follow
///          the lattice's §6 unification; anything else is a user operator
///          found under its op_name key and resolved as a call with the
///          receiver operand bound to `self`.
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
///   \par User operators
///     Candidates come from four places and rank in ONE set
///     (OverloadResolution::resolve_mixed), the sources C++ has
///     ([over.match.oper]/3): the receiver operand's members and extensions
///     (MemberLookup) under `DeclName::op_name(k0, k1)`; free operators found
///     by ADL in the modules of either operand's type; free operators in the
///     FILE either operand's type was declared in (MemberLookup::
///     declaring_scope); and free operators in unqualified scope at the use
///     site. Members take the receiver as `self`; frees take every operand as
///     an argument. The receiver is passed WITH the object's cv, so
///     `const v + w` needs an `op +(const self, ...)` exactly as a method call
///     would, and a use on a const object is X's error rather than clang's.
///
///   \par Derived operators
///     `!=` from `op ==`, and the four relationals from `op <=>`, when the
///     type declares no operator of its own (C++20's rewritten candidates,
///     minus the reversed ones). resolved_op is the underlying decl and
///     op_rewrite says how it is rendered; the lowering looks nothing up.
///
///     Compound assignment is ONE definition per pair. A type declares `op +`
///     or `op +=`, never both, and the other is derived: `a += b` is
///     `a = a + b` from `op +`; `a + b` is "copy a, `+=` b, yield the copy"
///     from `op +=`. Both applying to one use is the rule broken across scopes
///     and is an error here. An imported C++ type gets exactly what C++
///     declares. `a += b` on a record is a statement: its type is void.
///
///   \par `===`
///     Not overloadable. Valid when an operand is nullable: both non-null and
///     equal, a nullable pointer comparing what it points to. Typed here,
///     lowered by the nullable trio, never rewritten by OperatorLowering.
///
///   \par `^^`
///     On primitives a call to the `pow` lang item, typed like a shift: the
///     base's type is the result, the exponent is any integer typed on its
///     own. On a record, the user's `op ^^`.
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
import AST::OperatorFacts::*;
import Sema::Type::TypeUtil::*;
import Sema::Type::Conversion::*;
import Sema::Type::OverloadResolution::*;
import AST::Context::SymbolTable::*;
import AST::Context::DeclContext::*;
import AST::Context::InstantiationRegistry::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::LangItems::*;
import AST::Node::Base::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Kind::ExprKind::*;
import Token::Token::*;
import Token::TokenKind::*;
import Diagnostic::Registry::*;

class <T> OperatorTyping {
    priv inline fn dyn(self) -> *T { return static_cast::<*T>(&self); }

    // === classification of the operator token ===============================

    priv fn _is_arith(self, k: TokenKind) -> bool {
        return (k == TokenKind::OpPlus) || (k == TokenKind::OpMinus) || (k == TokenKind::OpStar)
            || (k == TokenKind::OpSlash) || (k == TokenKind::OpPercent);
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
    priv fn _is_inequality(self, k: TokenKind) -> bool {
        return (k == TokenKind::OpExclaimEqual) || (k == TokenKind::KwNotEq);
    }
    priv fn _is_relational(self, k: TokenKind) -> bool {
        return (k == TokenKind::OpLess) || (k == TokenKind::OpGreater)
            || (k == TokenKind::OpLessEqual) || (k == TokenKind::OpGreaterEqual);
    }

    /// Dependent in either sense: a type mentioning a generic parameter, and
    /// one whose ARGUMENTS do. Both mean "not knowable until instantiation".
    priv fn _is_dependent(self, t: *Type) -> bool {
        if t == &null { return false; }
        return t->is_dependent() || t->is_instantiation_dependent();
    }

    /// A class, struct or union. Not an enum: a plain enum compares natively.
    priv fn _is_plain_record(self, t: *Type) -> bool {
        var d = dyn()->tu.record_decl(dyn()->tu.strip_nullable(t));
        if d == &null { return false; }
        return isa::<ClassDecl>(d) || isa::<StructDecl>(d) || isa::<UnionDecl>(d);
    }

    priv fn _label(self, tok: Token) -> string {
        return "op " + dyn()->sc->ctx->get_spelling(tok);
    }

    /// §6 unification, or null. Operands are read as values; their
    /// top-level cv is gone by the time they meet.
    fn unify_operands(self, a_in: *Type, b_in: *Type) -> *Type {
        if (a_in == &null) || (b_in == &null) { return &null; }
        var a = dyn()->tu.as_value(a_in);
        var b = dyn()->tu.as_value(b_in);
        if a == b { return a; }
        var ab = dyn()->conv.implicit(a, b);
        var ba = dyn()->conv.implicit(b, a);
        if (ab != ImplicitRank::None) && (ba == ImplicitRank::None) { return b; }
        if (ba != ImplicitRank::None) && (ab == ImplicitRank::None) { return a; }
        return &null;
    }

    // === user operators: candidates ==========================================

    /// The cv of the object \p t denotes: through any C++ reference (a
    /// reference is its referee), not through a pointer. MemberTyping reads a
    /// method call's receiver the same way.
    priv fn _object_quals(self, t: *Type) -> u8 {
        var c = t;
        while c != &null {
            if isa::<CXXLValueRefType>(c) { c = cast::<CXXLValueRefType>(c)->referee; continue; }
            if isa::<CXXRValueRefType>(c) { c = cast::<CXXRValueRefType>(c)->referee; continue; }
            break;
        }
        return canon_quals(c);
    }

    /// The receiver OverloadResolution ranks `self` / `const self` against:
    /// the operand's value type carrying the object's cv. as_value() strips
    /// both, which is right for the result type and wrong here.
    priv fn _receiver_of(self, e: *Expr) -> *Type {
        if (e == &null) || (e->type_ == &null) { return &null; }
        var q = self._object_quals(e->type_);
        var v = dyn()->tu.strip_nullable(dyn()->tu.as_value(e->type_));
        if v == &null { return &null; }
        return dyn()->sc->types->qualified(v, q);
    }

    /// The scope an unqualified `op +` would be looked up from here: the
    /// enclosing function (an out-of-line body's is its owner's), else the TU.
    priv fn _use_site_scope(self) -> *DeclContext {
        var n = dyn()->frames.size();
        for var i: usize = 0; i < n; ++i {
            var fr = &(dyn()->frames[(n - 1) - i]);
            if fr->fn_decl != &null { return static_cast::<*DeclContext>(fr->fn_decl); }
        }
        return static_cast::<*DeclContext>(dyn()->sc->tu);
    }

    priv fn _has(self, v: *vec::<*Decl>, d: *Decl) -> bool {
        for var i: usize = 0; i < v->size(); ++i { if (*v)[i] == d { return true; } }
        return false;
    }

    /// Everything named \p name that applies with \p recv_ty as the receiver:
    /// members and extension members into \p cands, free operators into
    /// \p frees. \p other is the other operand's type or null. For `++`/`--`
    /// \p want_postfix (0 prefix, 1 postfix, -1 either) drops the wrong fixity:
    /// `op l++` and `op r++` share a cell and differ only there.
    priv fn _gather(self, name: DeclName, recv_ty: *Type, other: *Type, want_postfix: i32,
                    cands: *vec::<*Decl>, frees: *vec::<*Decl>) {
        if recv_ty != &null { dyn()->ml.lookup(dyn()->tu.strip_nullable(recv_ty), name, cands); }

        var scopes = vec::<*DeclContext>();
        if recv_ty != &null {
            dyn()->ml.associated_scopes(recv_ty, &scopes);
            dyn()->ml.declaring_scope(recv_ty, &scopes);
        }
        if other != &null {
            dyn()->ml.associated_scopes(other, &scopes);
            dyn()->ml.declaring_scope(other, &scopes);
        }
        dyn()->ml.adl_candidates(&scopes, name, "", cands, frees);

        // The use site. A member reached this way (an operator of the
        // enclosing type, from inside one of its methods) already came through
        // ml.lookup if it applies; only free functions are new here.
        var r = dyn()->sc->lookup.unqualified(self._use_site_scope(), name);
        if r.found() {
            for var i: usize = 0; i < r.cell->size(); ++i {
                var d = r.cell->get(i);
                var f = dyn_cast::<FunctionDecl>(d);
                if (f == &null) || f->is_method() { continue; }
                if self._has(cands, d) || self._has(frees, d) { continue; }
                frees->push_back(d);
            }
        }

        if want_postfix < 0 { return; }
        self._filter_fixity(cands, want_postfix == 1);
        self._filter_fixity(frees, want_postfix == 1);
    }

    priv fn _filter_fixity(self, v: *vec::<*Decl>, postfix: bool) {
        var keep = vec::<*Decl>();
        for var i: usize = 0; i < v->size(); ++i {
            var f = dyn_cast::<FunctionDecl>((*v)[i]);
            if (f != &null) && (OperatorFacts::is_postfix(f) != postfix) { continue; }
            keep.push_back((*v)[i]);
        }
        (*v) = keep;
    }

    /// Record the winner on the operator node. OperatorLowering reads these
    /// and never looks an operator up again.
    priv fn _record(self, n: *Expr, d: *Decl, via_free: bool, inst: *InstanceEntry) {
        var iv = reinterpret_cast::<*void>(inst);
        switch n->kind {
            case ExprKind::BinaryOperatorExpr {
                var b = cast::<BinaryOperatorExpr>(n);
                b->resolved_op = d; b->op_via_free = via_free; b->op_instance = iv;
            }
            case ExprKind::UnaryOperatorExpr {
                var u = cast::<UnaryOperatorExpr>(n);
                u->resolved_op = d; u->op_via_free = via_free; u->op_instance = iv;
            }
            case ExprKind::AssignOperatorExpr {
                var a = cast::<AssignOperatorExpr>(n);
                a->resolved_op = d; a->op_via_free = via_free; a->op_instance = iv;
            }
            default { ICE_FAIL("OperatorTyping: _record on a node that carries no resolved_op"); }
        }
    }

    /// Resolve `op <k0 k1>` with \p recv as the receiver operand and \p args
    /// as the rest. \p found reports whether ANY candidate existed, so the
    /// caller falls back (a derived operator, builtin equality) only when the
    /// type declared nothing. On Selected: records the winner on \p n and
    /// returns the call's result type; on failure the node is poisoned or
    /// marked unknown and null comes back.
    fn resolve_user_op(self, n: *Expr, k0: TokenKind, k1: TokenKind, recv: *Expr, recv_ty: *Type,
                       other: *Type, args: *vec::<*Expr>, want_postfix: i32, label: string,
                       found: *bool) -> *Type {
        (*found) = false;
        if recv_ty == &null { return &null; }
        var name  = DeclName::op_name(k0, k1);
        var cands = vec::<*Decl>();
        var frees = vec::<*Decl>();
        self._gather(name, recv_ty, other, want_postfix, &cands, &frees);
        if (cands.size() == 0) && (frees.size() == 0) { return &null; }
        (*found) = true;

        var margs = vec::<ArgInfo>();
        for var i: usize = 0; i < args->size(); ++i { margs.push_back(dyn()->arg_info((*args)[i])); }
        // A free operator takes the receiver operand as its first argument.
        var fargs = vec::<ArgInfo>();
        fargs.push_back(dyn()->arg_info(recv));
        for var i: usize = 0; i < margs.size(); ++i { fargs.push_back(margs[i]); }

        var r = dyn()->ovl.resolve_mixed(&cands, &margs, true, &frees, &fargs, n->range, label,
                                         self._receiver_of(recv));
        if r.outcome == OvlOutcome::Dependent { dyn()->mark_unknown(n); return &null; }
        if r.outcome != OvlOutcome::Selected { dyn()->poison_only(n); return &null; }
        dyn()->finish_call_args(r.decl, (&fargs) if (r.via_free) else (&margs), &r);
        var rt = dyn()->call_result_type(r.decl, &r);
        self._record(n, static_cast::<*Decl>(r.decl), r.via_free, r.instance);
        return rt;
    }

    /// An ArgInfo for an operand X already typed: never re-shaped as an
    /// untyped literal. `2.0 ^^ 3` with an expected f32 typed the base f32,
    /// and ranking its SHAPE would deduce the lang item's B as f64.
    priv fn _typed_arg(self, e: *Expr, t: *Type) -> ArgInfo {
        var a = dyn()->arg_info(e);
        a.lit       = LitKind::None;
        a.ty        = t;
        a.dependent = false;
        return a;
    }

    // === binary =============================================================

    fn type_binary(self, n: *BinaryOperatorExpr, expected: *Type) -> *Type {
        var k = n->op_token.kind;

        // `^^` types its operands independently, like a shift: the base takes
        // the expected type, the exponent is its own integer.
        if k == TokenKind::OpCaretCaret { return self._type_pow(n, expected); }

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
        // Every builtin result below is a prvalue; the user-operator path
        // reads the receiver's cv off the operand node itself.
        lt = dyn()->tu.as_value(lt);
        rt = dyn()->tu.as_value(rt);

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

        if k == TokenKind::OpEqualEqualEqual { return self._type_identity(n, lt, rt); }
        if k == TokenKind::KwIn              { return self._type_contains(n, lt, rt); }

        // user operator on a record / extended type.
        var lb = dyn()->tu.kind_of(lt) != BuiltinKind::COUNT;
        var rb = dyn()->tu.kind_of(rt) != BuiltinKind::COUNT;
        if !(lb && rb) {
            var found = false;
            var args  = vec::<*Expr>();
            args.push_back(n->rhs);
            var ut = self.resolve_user_op(static_cast::<*Expr>(n), k, TokenKind::TkUnknown, n->lhs, lt, rt,
                                          &args, -1, self._label(n->op_token), &found);
            if found { return ut; }

            // Derived: `!=` from `op ==`.
            if self._is_inequality(k) {
                ut = self.resolve_user_op(static_cast::<*Expr>(n), TokenKind::OpEqualEqual, TokenKind::TkUnknown,
                                          n->lhs, lt, rt, &args, -1, "op ==", &found);
                if found {
                    if ut == &null { return &null; }
                    n->op_rewrite = OpRewrite::Not;
                    return dyn()->tu.builtin(BuiltinKind::Bool);
                }
            }
            // Derived: `<` `<=` `>` `>=` from `op <=>`.
            if self._is_relational(k) {
                ut = self.resolve_user_op(static_cast::<*Expr>(n), TokenKind::OpLessEqualGreater, TokenKind::TkUnknown,
                                          n->lhs, lt, rt, &args, -1, "op <=>", &found);
                if found {
                    if ut == &null { return &null; }
                    n->op_rewrite = OpRewrite::Cmp;
                    return dyn()->tu.builtin(BuiltinKind::Bool);
                }
            }
            // Derived: `a + b` from `op +=` -- copy a, `+=` b, yield the copy.
            // The node's type is the LHS's, not the call's (void).
            var ck = OperatorFacts::compound_of(k);
            if (ck != TokenKind::TkUnknown) && (!decl_is_imported(dyn()->tu.record_decl(lt))) {
                ut = self.resolve_user_op(static_cast::<*Expr>(n), ck, TokenKind::TkUnknown, n->lhs, lt, rt,
                                          &args, -1, self._label(n->op_token), &found);
                if found {
                    if n->is_poisoned() || n->is_instantiation_dependent() { return &null; }
                    return canon_unqual(lt);
                }
            }

            // No user operator. Equality is builtin on pointers, nullables and
            // plain enums; a record compares only through its own `op ==`.
            if self._is_equality(k) {
                if self._is_plain_record(lt) || self._is_plain_record(rt) {
                    var rec = (lt) if (self._is_plain_record(lt)) else (rt);
                    dyn()->fail(n, f"no 'op ==' on '{dyn()->tu.str(rec)}'; a record compares only through its own operator");
                    return &null;
                }
                if self.unify_operands(lt, rt) != &null { return dyn()->tu.builtin(BuiltinKind::Bool); }
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

    /// `a === b`: both non-null and equal. Needs a nullable operand; a
    /// nullable pointer compares what it points to, so the pointees unify.
    priv fn _type_identity(self, n: *BinaryOperatorExpr, lt: *Type, rt: *Type) -> *Type {
        var ln = dyn()->tu.nullable_inner(lt);
        var rn = dyn()->tu.nullable_inner(rt);
        if (ln == &null) && (rn == &null) {
            dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                f"'===' needs a nullable operand; '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}' are not nullable"
            ).first(n->range)
             .note(n->range.start, "'===' is 'both present and equal'; on values that cannot be null it is '==\x27")
             .emit();
            n->poison();
            return &null;
        }
        var li = dyn()->tu.strip_nullable(lt);
        var ri = dyn()->tu.strip_nullable(rt);
        var lp = dyn()->tu.pointee(li);
        var rp = dyn()->tu.pointee(ri);
        if lp != &null { li = lp; }
        if rp != &null { ri = rp; }
        if self._is_plain_record(li) || self._is_plain_record(ri) {
            dyn()->fail(n, f"'===' on '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}' would compare records, which have no builtin equality");
            return &null;
        }
        if self.unify_operands(li, ri) == &null {
            dyn()->fail(n, f"'===' operands '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}' do not unify");
            return &null;
        }
        return dyn()->tu.builtin(BuiltinKind::Bool);
    }

    /// `x in xs`: containment. The RIGHT operand is the receiver -- xs's
    /// `op in (self, x)`, or a free `op in (xs, x)`. The iteration form
    /// `op in (self)` shares the name and drops out on arity.
    priv fn _type_contains(self, n: *BinaryOperatorExpr, lt: *Type, rt: *Type) -> *Type {
        var found = false;
        var args  = vec::<*Expr>();
        args.push_back(n->lhs);
        var ut = self.resolve_user_op(static_cast::<*Expr>(n), TokenKind::KwIn, TokenKind::TkUnknown, n->rhs, rt, lt,
                                      &args, -1, "op in", &found);
        if found { return ut; }
        dyn()->fail(n, f"'in' needs an 'op in' on '{dyn()->tu.str(rt)}' taking a '{dyn()->tu.str(lt)}\x27");
        return &null;
    }

    /// `b ^^ e`. A record base goes through its `op ^^`; a primitive base is
    /// a call to the `pow` lang item, whose `B` deduces from the base and `E`
    /// from the exponent, so the result IS the base's type.
    priv fn _type_pow(self, n: *BinaryOperatorExpr, expected: *Type) -> *Type {
        var lt = dyn()->type_of(n->lhs, expected);
        var rt = dyn()->type_of(n->rhs, &null);
        if dyn()->propagate(n, n->lhs) || dyn()->propagate(n, n->rhs) { return &null; }
        if (lt == &null) || (rt == &null) { return &null; }
        lt = dyn()->tu.as_value(lt);
        rt = dyn()->tu.as_value(rt);
        if self._is_dependent(lt) || self._is_dependent(rt) { dyn()->mark_unknown(n); return &null; }

        if dyn()->tu.kind_of(lt) == BuiltinKind::COUNT {
            var found = false;
            var args  = vec::<*Expr>();
            args.push_back(n->rhs);
            var ut = self.resolve_user_op(static_cast::<*Expr>(n), TokenKind::OpCaretCaret, TokenKind::TkUnknown,
                                          n->lhs, lt, rt, &args, -1, "op ^^", &found);
            if found { return ut; }
            dyn()->fail(n, f"no 'op ^^' on '{dyn()->tu.str(lt)}\x27");
            return &null;
        }
        if !dyn()->tu.is_numeric(lt) {
            dyn()->fail(n, f"'^^' needs a numeric base, not '{dyn()->tu.str(lt)}\x27");
            return &null;
        }
        if !dyn()->tu.is_integer(rt) {
            if dyn()->tu.is_float(rt) {
                dyn()->fail(n, f"the exponent of '^^' must be an integer, not '{dyn()->tu.str(rt)}'; a real exponent is a library function");
            } else {
                dyn()->fail(n, f"the exponent of '^^' must be an integer, not '{dyn()->tu.str(rt)}\x27");
            }
            return &null;
        }

        var d = dyn()->sc->well_known->get(WellKnownType::Pow);
        if d == &null { dyn()->missing_lang_item(n, "pow"); return &null; }
        var cands = vec::<*Decl>();
        cands.push_back(d);
        var fargs = vec::<ArgInfo>();
        fargs.push_back(self._typed_arg(n->lhs, lt));
        fargs.push_back(self._typed_arg(n->rhs, rt));
        var r = dyn()->ovl.resolve(&cands, &fargs, false, n->range, "op ^^");
        if r.outcome == OvlOutcome::Dependent { dyn()->mark_unknown(n); return &null; }
        if r.outcome != OvlOutcome::Selected { dyn()->poison_only(n); return &null; }
        dyn()->finish_call_args(r.decl, &fargs, &r);
        dyn()->call_result_type(r.decl, &r);   // registers the instance; B := lt.
        self._record(static_cast::<*Expr>(n), static_cast::<*Decl>(r.decl), true, r.instance);
        return canon_unqual(lt);
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
        // `v.at(i)` is `i32&`; every arm below classifies the value it names,
        // and `&`/`*` want the referee too -- `&v.at(i)` is `*i32`, as in C++.
        ot = dyn()->tu.as_value(ot);

        // user operator first for non-primitives. `++`/`--` keep only the
        // declared fixity that matches the use.
        if (dyn()->tu.kind_of(ot) == BuiltinKind::COUNT) && (!self._is_dependent(ot))
        && (k != TokenKind::OpAmp) && (k != TokenKind::OpStar) {
            var fix: i32 = -1;
            if (k == TokenKind::OpPlusPlus) || (k == TokenKind::OpMinusMinus) { fix = (1) if (n->is_postfix()) else (0); }
            var found = false;
            var args  = vec::<*Expr>();
            var ut = self.resolve_user_op(static_cast::<*Expr>(n), k, TokenKind::TkUnknown, n->operand, ot, &null,
                                          &args, fix, self._label(n->op_token), &found);
            if found { return ut; }
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
            var what = ("'++\x27") if (n->op_token.kind == TokenKind::OpPlusPlus) else ("'--\x27");
            if dyn()->tu.kind_of(ot) == BuiltinKind::COUNT {
                var fixname = ("r") if (n->is_postfix()) else ("l");
                dyn()->fail(n, f"no 'op {fixname}{dyn()->sc->ctx->get_spelling(n->op_token)}' on '{dyn()->tu.str(ot)}\x27");
                return &null;
            }
            dyn()->fail(n, f"{what} requires an integer operand, not '{dyn()->tu.str(ot)}\x27");
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
        // The assigned-to object, not the reference naming it: `v.at(i) = 5`
        // assigns an `i32`. The lvalue test below still reads the NODE's
        // category, which _default_category already set to LValue for a `T&`
        // result, so the reference stays assignable.
        lt = dyn()->tu.as_value(lt);

        if !dyn()->is_lvalue(n->lhs) {
            dyn()->fail(n, "left side of assignment is not assignable");
            dyn()->type_of(n->rhs, &null);
            return &null;
        }

        if k == TokenKind::OpEqual {
            var lc = canon_unqual(lt);
            if (lc != &null) && isa::<FixedArrayType>(lc) {
                dyn()->type_of(n->rhs, lt);
                dyn()->fail(n, "an array is not assignable; assign its elements, or go through a slice");
                return &null;
            }
            dyn()->type_of(n->rhs, lt);
            if dyn()->propagate(n, n->rhs) { return &null; }
            if dyn()->reject_slice_literal(n->rhs, "assigned to a slice") { dyn()->poison_only(n); return &null; }
            if !dyn()->check_convertible(n->rhs, lt) { dyn()->poison_only(n); return &null; }
            n->value_category = Expr::ValueCategory::LValue;
            return lt;
        }

        // compound: the underlying binary op's rules, converting the RIGHT
        // operand only (§6).
        var base = OperatorFacts::compound_base(k);
        var rt   = dyn()->type_of(n->rhs, lt);
        if dyn()->propagate(n, n->rhs) { return &null; }
        if rt == &null { return &null; }
        rt = dyn()->tu.as_value(rt);
        if self._is_dependent(lt) || self._is_dependent(rt) { dyn()->mark_unknown(n); return &null; }

        var l_rec = dyn()->tu.kind_of(lt) == BuiltinKind::COUNT;
        var r_rec = dyn()->tu.kind_of(rt) == BuiltinKind::COUNT;
        if l_rec || r_rec {
            var t = self._type_compound(n, k, base, lt, rt);
            if (t != &null) || n->is_poisoned() || n->is_instantiation_dependent() { return t; }
            // Primitive left, record right, nothing declared: the builtin
            // checks below say what is wrong with it.
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

    /// `a += b` with a record on either side. ONE definition per pair: the
    /// type's `op +=` if it declares one, else its `op +` with `a = a + b`
    /// semantics (OperatorLowering renders either from resolved_op). Both
    /// applying is the rule broken across scopes. An imported C++ type gets
    /// exactly what C++ declares. The expression is a statement: void.
    ///
    /// Returns null with the node untouched when nothing at all applies and
    /// the left side is primitive, so the builtin checks report it.
    priv fn _type_compound(self, n: *AssignOperatorExpr, k: TokenKind, base: TokenKind,
                           lt: *Type, rt: *Type) -> *Type {
        var l_rec = dyn()->tu.kind_of(lt) == BuiltinKind::COUNT;
        var foreign = l_rec && decl_is_imported(dyn()->tu.record_decl(lt));

        var c_cands = vec::<*Decl>(); var c_frees = vec::<*Decl>();
        var b_cands = vec::<*Decl>(); var b_frees = vec::<*Decl>();
        self._gather(DeclName::op_name(k, TokenKind::TkUnknown), lt, rt, -1, &c_cands, &c_frees);
        if !foreign { self._gather(DeclName::op_name(base, TokenKind::TkUnknown), lt, rt, -1, &b_cands, &b_frees); }
        var has_c = (c_cands.size() > 0) || (c_frees.size() > 0);
        var has_b = (b_cands.size() > 0) || (b_frees.size() > 0);

        if has_c && has_b {
            var bsp = dyn()->sc->ctx->get_spelling(n->op_token);
            dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                f"both an 'op {bsp}' and its base operator apply to '{dyn()->tu.str(lt)}'; a type declares one and the other is derived from it"
            ).first(n->range).emit();
            n->poison();
            return &null;
        }
        if !(has_c || has_b) {
            if !l_rec { return &null; }
            dyn()->fail(n, f"no operator '{dyn()->sc->ctx->get_spelling(n->op_token)}' on '{dyn()->tu.str(lt)}\x27");
            return &null;
        }

        var found = false;
        var args  = vec::<*Expr>();
        args.push_back(n->rhs);
        var rk = (k) if (has_c) else (base);
        var ut = self.resolve_user_op(static_cast::<*Expr>(n), rk, TokenKind::TkUnknown, n->lhs, lt, rt,
                                      &args, -1, self._label(n->op_token), &found);
        if n->is_poisoned() || n->is_instantiation_dependent() { return &null; }
        if has_b {
            // `a = a + b`: the sum must be assignable to a. The rule is `=`'s
            // (an implicit conversion); a converting constructor is not one.
            if (ut != &null) && (dyn()->conv.implicit(dyn()->tu.as_value(ut), canon_unqual(lt)) == ImplicitRank::None) {
                dyn()->fail(n, f"'op {dyn()->sc->ctx->get_spelling(n->op_token)}' derived from the base operator would assign a '{dyn()->tu.str(ut)}' to a '{dyn()->tu.str(lt)}\x27");
                return &null;
            }
        }
        n->value_category = Expr::ValueCategory::RValue;
        return dyn()->tu.builtin(BuiltinKind::Void);
    }
}