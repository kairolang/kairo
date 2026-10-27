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
///     Comparison uses the same unification and yields bool; a shift's left
///     operand takes the expected type and its right operand is typed
///     independently; compound assignment converts the right operand only.
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
///     minus the reversed ones). `==` and `!=` also come from `op <=>` when
///     there is no `op ==` -- Kairo's rule, not C++'s, so never on an
///     imported record. resolved_op is the underlying decl and op_rewrite
///     says how it is rendered; the lowering looks nothing up. A declared
///     comparison always wins over the derived one (OperatorSignatureCheck
///     warns that it shadows it); InterfaceEmitter writes the derived six
///     into the C++ class, so a C++ host sees what Kairo does.
///
///     Compound assignment is ONE definition per pair. A type declares `op +`
///     or `op +=`, never both, and the other is derived: `a += b` is
///     `a = a + b` from `op +`; `a + b` is "copy a, `+=` b, yield the copy"
///     from `op +=`. Both applying to one use is the rule broken across scopes
///     and is an error here. An imported C++ type gets exactly what C++
///     declares. `a += b` on a record is a statement: its type is void.
///
///   \par ADT `==`
///     `==` / `!=` on two values of one ADT enum that declares no `op ==`
///     compares the variants, not the payloads. No operator is bound: the
///     node's tag_eq is set and OperatorLowering writes the compare of the
///     two tag fields. The user lookup runs first, so an `op ==` from any
///     source replaces it. A nullable ADT operand keeps builtin equality;
///     two instances of one generic enum have no `==`.
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
import Sema::Type::NullnessFlow::*;
import Sema::Type::Conversion::*;
import Sema::Type::OverloadResolution::*;
import Sema::Resolve::NameLookup::*;
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

    /// The interfaces a bounded generic parameter \p t promises, as their
    /// canonical instances (`T impl Same`, `T impl Container<U>`), or none
    /// when \p t is not a bare parameter or has no interface bound. An
    /// operator on such an operand is the bound's requirement, as a member
    /// call on it is (ChainBinding's dependent path): binding it here is what
    /// sends it through the interface's witness (CODEGEN.md §7b.5).
    /// MemberTyping's `op []` reads it too, so a subscript and a binary
    /// operator on one T see the same bounds.
    fn bound_ifaces(self, t: *Type) -> vec::<*Type> {
        var out = vec::<*Type>();
        var c = canon_unqual(t);
        if (c == &null) || (!isa::<GenericParamType>(c)) { return out; }
        var g = cast::<GenericParamType>(c);
        var it = dyn()->sc->bounds.find(reinterpret_cast::<u64>(g->owner));
        if it == dyn()->sc->bounds.end() { return out; }
        var _set = &(it->second);
        for var i: usize = 0; i < _set->impl_constraints.size(); ++i {
            var k = _set->impl_constraints[i];
            var id = dyn_cast::<NamedIdentExpr>(k->lhs);
            if id == &null { continue; }
            var gp = dyn_cast::<GenericParamDecl>(id->resolved_decl);
            if (gp == &null) || (gp->index != g->param_index) { continue; }
            if NameLookup::representative(gp->owner) != NameLookup::representative(g->owner) { continue; }
            if (k->rhs == &null) || (k->rhs->canonical == &null) { continue; }
            out.push_back(canon_unqual(k->rhs->canonical));
        }
        return out;
    }

    priv fn _bounded(self, t: *Type) -> bool { return self.bound_ifaces(t).size() > 0; }

    /// A class, struct or union. Not an enum: a plain enum compares natively.
    priv fn _is_plain_record(self, t: *Type) -> bool {
        var d = dyn()->tu.record_decl(dyn()->tu.strip_nullable(t));
        if d == &null { return false; }
        return isa::<ClassDecl>(d) || isa::<StructDecl>(d) || isa::<UnionDecl>(d);
    }

    /// A record imported from a C++ header (not a Kairo one), or an instance
    /// of an imported template: `__wrap_iter<const int*>` is clang's
    /// instantiation, and only its primary carries the import stamp.
    priv fn _is_imported_record(self, t: *Type) -> bool {
        var d = dyn()->tu.record_decl(t);
        if d == &null { return false; }
        if decl_is_imported(d) { return true; }
        return decl_is_instance(d) && decl_is_imported(decl_instantiated_from(d));
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
        // implicit_builtin: operands unify on the lattice, never through a
        // user's `@implicit op as` (see Conversion::join).
        var ab = dyn()->conv.implicit_builtin(a, b);
        var ba = dyn()->conv.implicit_builtin(b, a);
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
        // A bounded parameter offers its bounds' requirements and nothing
        // else: no ADL, no free operator, since neither can be known to apply
        // to every T the bound admits.
        var bound = self.bound_ifaces(recv_ty);
        if bound.size() > 0 {
            for var i: usize = 0; i < bound.size(); ++i { dyn()->ml.lookup(bound[i], name, cands); }
            return;
        }
        if recv_ty != &null { dyn()->ml.lookup(dyn()->tu.strip_nullable(recv_ty), name, cands); }
        // A C++ hidden friend sits in its class's table but is no member: it
        // takes every operand as an argument, and ADL reaches it through
        // EITHER operand's class (DeclImport::declare_friend).
        self._move_friends(cands, frees);
        if (other != &null) && (dyn()->tu.record_decl(other) != &null) {
            var theirs = vec::<*Decl>();
            dyn()->ml.lookup(dyn()->tu.strip_nullable(other), name, &theirs);
            for var i: usize = 0; i < theirs.size(); ++i {
                var f = dyn_cast::<FunctionDecl>(theirs[i]);
                if (f == &null) || f->is_method() { continue; }
                if self._has(frees, theirs[i]) { continue; }
                frees->push_back(theirs[i]);
            }
        }

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

        self._filter_free_applies(frees, recv_ty, other);

        if want_postfix < 0 { return; }
        self._filter_fixity(cands, want_postfix == 1);
        self._filter_fixity(frees, want_postfix == 1);
    }

    /// Move the non-methods member lookup found (hidden friends) to \p frees.
    priv fn _move_friends(self, cands: *vec::<*Decl>, frees: *vec::<*Decl>) {
        var keep = vec::<*Decl>();
        for var i: usize = 0; i < cands->size(); ++i {
            var f = dyn_cast::<FunctionDecl>((*cands)[i]);
            if (f != &null) && (!f->is_method()) && decl_is_imported((*cands)[i]) {
                if !self._has(frees, (*cands)[i]) { frees->push_back((*cands)[i]); }
                continue;
            }
            keep.push_back((*cands)[i]);
        }
        (*cands) = keep;
    }

    /// Drop the free operators that cannot take these operands at all. A
    /// free operator is reached by NAME from the use site, so `op +(F, F)`
    /// at file scope is in every `+`'s cell -- and a candidate that exists
    /// is what `found` means to every caller: it suppresses the derived
    /// forms, builtin enum equality, and makes `+=` beside a type's own
    /// `op +=` look like both halves of a pair. Arity and an implicit
    /// conversion per operand decide it; a dependent parameter is the
    /// instantiation's to decide, so it stays.
    priv fn _filter_free_applies(self, v: *vec::<*Decl>, recv_ty: *Type, other: *Type) {
        var keep = vec::<*Decl>();
        for var i: usize = 0; i < v->size(); ++i {
            var f = dyn_cast::<FunctionDecl>((*v)[i]);
            if (f == &null) || self._free_may_apply(f, recv_ty, other) { keep.push_back((*v)[i]); }
        }
        (*v) = keep;
    }

    priv fn _free_may_apply(self, f: *FunctionDecl, recv_ty: *Type, other: *Type) -> bool {
        if f->is_variadic || (f->generic_params.size() > 0) { return true; }
        var want: usize = (2) if (other != &null) else (1);
        if f->params.size() != want { return false; }
        if !self._operand_fits(f->params[0], recv_ty) { return false; }
        if (other != &null) && (!self._operand_fits(f->params[1], other)) { return false; }
        return true;
    }

    priv fn _operand_fits(self, p: *ParamDecl, t: *Type) -> bool {
        if (p == &null) || (p->type_ == &null) || (p->type_->canonical == &null) { return true; }
        if (t == &null) || p->type_->is_dependent() { return true; }
        var pt = canon_unqual(p->type_->canonical);
        return dyn()->conv.implicit(canon_unqual(dyn()->tu.as_value(t)), pt) != ImplicitRank::None;
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
    ///
    /// \p viable_only: a candidate set none of which takes these operands
    /// counts as not found, silently -- C++20's rule for the operators it
    /// rewrites (`!=` from `==`, `<` from `<=>`), where a viable rewritten
    /// candidate wins over a non-viable direct one.
    fn resolve_user_op(self, n: *Expr, k0: TokenKind, k1: TokenKind, recv: *Expr, recv_ty: *Type,
                       other: *Type, args: *vec::<*Expr>, want_postfix: i32, label: string,
                       found: *bool, viable_only: bool = false) -> *Type {
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

        if viable_only && (!dyn()->ovl.any_viable(&cands, &margs, true, &frees, &fargs, self._receiver_of(recv))) {
            (*found) = false;
            return &null;
        }

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

    /// \p t, unless \p e is a cast. A cast types its operand against its own
    /// target and never reads the expected type, so withholding it changes
    /// nothing but the redundant-cast lint: an operand is not a slot that
    /// already takes the source, and there the cast is what picks the width
    /// the operator runs at (`(b as u16) << 8`). See _lint_widening.
    fn cast_operand_expected(self, e: *Expr, t: *Type) -> *Type {
        if isa::<TypeCastExpr>(dyn()->tu.strip_parens(e)) { return &null; }
        return t;
    }

    fn type_binary(self, n: *BinaryOperatorExpr, expected: *Type) -> *Type {
        var k = n->op_token.kind;

        // `^^` types its operands independently, like a shift: the base takes
        // the expected type, the exponent is its own integer.
        if k == TokenKind::OpCaretCaret { return self._type_pow(n, expected); }

        // `x == null` and the other three spellings are the null test
        // (NULLABLE.md 2.2). Asked before the operands are typed: a `null`
        // typed against a non-nullable would report "cannot infer the type
        // of null" and hide the real mistake.
        if self._is_equality(k) {
            var nl = null_literal_of(n->lhs);
            var nr = null_literal_of(n->rhs);
            if (nl != &null) != (nr != &null) {
                var done = false;
                var t = self._type_null_compare(n, (nl) if (nl != &null) else (nr), (n->rhs) if (nl != &null) else (n->lhs), &done);
                if done { return t; }
            }
        }

        // `x === null` asks for both sides present, so it is never true: a
        // null test misspelled (NULLABLE.md 2.3). Before the operands are
        // typed, as for `== null`: the literal has nothing to take a type from.
        if k == TokenKind::OpEqualEqualEqual {
            var nl = null_literal_of(n->lhs);
            var nr = null_literal_of(n->rhs);
            if (nl != &null) || (nr != &null) { return self._identity_null(n, nl != &null); }
        }

        // `&&` / `||`: the right side runs only on one of the left side's
        // outcomes, so it is typed under that outcome's nullness facts
        // (NULLABLE.md 3.3). Both sides are typed here, in order; the
        // operand typing below is then a memo hit.
        if self._is_logical(k) { self._type_logical_operands(n); }

        // literal on one side takes the other's type.
        var l_lit = dyn()->is_untyped_literal(n->lhs);
        var r_lit = dyn()->is_untyped_literal(n->rhs);
        var lt: *Type = &null;
        var rt: *Type = &null;
        var numeric_ctx = self._is_arith(k) || self._is_bitwise(k) || self._is_equality(k) || self._is_relational(k);
        var pass_down: *Type = (expected) if (self._is_arith(k) || self._is_bitwise(k)) else (&null);
        // A shift's result IS its left operand's type, so the left operand
        // takes the expected type (`var m: u8 = 1 << 3` is a u8 shift, as `^^`'s
        // base is); the count stays its own integer.
        var lhs_down: *Type = (expected) if (self._is_shift(k)) else (pass_down);

        if l_lit && (!r_lit) {
            rt = dyn()->type_of(n->rhs, self.cast_operand_expected(n->rhs, pass_down));
            lt = dyn()->type_of(n->lhs, (rt) if (numeric_ctx) else ((self._identity_down(rt, lhs_down)) if (k == TokenKind::OpEqualEqualEqual) else (lhs_down)));
        } else if r_lit && (!l_lit) {
            lt = dyn()->type_of(n->lhs, self.cast_operand_expected(n->lhs, lhs_down));
            rt = dyn()->type_of(n->rhs, (lt) if (numeric_ctx) else (self._coalesce_down(k, lt, pass_down)));
        } else {
            lt = dyn()->type_of(n->lhs, self.cast_operand_expected(n->lhs, lhs_down));
            rt = dyn()->type_of(n->rhs, self.cast_operand_expected(n->rhs, (lt) if (numeric_ctx && (pass_down == &null)) else (self._coalesce_down(k, lt, pass_down))));
        }
        if dyn()->propagate(n, n->lhs) || dyn()->propagate(n, n->rhs) { return &null; }
        if (lt == &null) || (rt == &null) { return &null; }
        // Every builtin result below is a prvalue; the user-operator path
        // reads the receiver's cv off the operand node itself.
        lt = dyn()->tu.as_value(lt);
        rt = dyn()->tu.as_value(rt);

        // A nullable operand of an operator that computes with it is a read
        // of its value (NULLABLE.md §4): narrowed when its place is proven
        // non-null here, else the nullness error, never "no operator for
        // 'i32?'". `==` / `!=` compare nullables as they are (`a == 5` is
        // false on a null `a`), so they only take a proven value, when the
        // other side is no nullable; `??`, `===` and `in` take the nullable.
        if self._reads_operands(k) {
            if dyn()->tu.nullable_inner(lt) != &null {
                var nl = dyn()->read_value(n->lhs);
                if nl == &null { dyn()->poison_only(n); return &null; }
                lt = dyn()->tu.as_value(nl);
            }
            if dyn()->tu.nullable_inner(rt) != &null {
                var nr = dyn()->read_value(n->rhs);
                if nr == &null { dyn()->poison_only(n); return &null; }
                rt = dyn()->tu.as_value(nr);
            }
        } else if self._is_equality(k) && ((dyn()->tu.nullable_inner(lt) != &null) != (dyn()->tu.nullable_inner(rt) != &null)) {
            var side = (n->lhs) if (dyn()->tu.nullable_inner(lt) != &null) else (n->rhs);
            if dyn()->flow.read_value(side, false) == NULL_READ_NARROWED() {
                lt = dyn()->tu.as_value(n->lhs->type_);
                rt = dyn()->tu.as_value(n->rhs->type_);
            }
        }

        // A DEPENDENT operand has no operator table yet: which `op +` applies
        // to `T` is decided by the instantiation, not here. Rejecting it at
        // definition time would make every generic that adds ill-formed, so
        // the answer is deferred (M2) rather than diagnosed. A left operand
        // that is a BOUNDED parameter is the exception: its bounds say which
        // operators it has, and the user-operator path below binds one.
        // `??`, `===` and `in` are never the left operand's user operator
        // (`in` is the RIGHT operand's), so they defer on any dependent
        // operand, bounded or not.
        // `t ?? d` in a generic body, `t: T?`: the arms of its expansion
        // are `T` and `d`'s type, so when those are one type (or `d` is that
        // `T?`) the answer needs no instantiation, and CoalesceLowering can
        // expand the template like any other body. Anything else defers.
        if (k == TokenKind::OpQuestionQuestion) && (self._is_dependent(lt) || self._is_dependent(rt)) {
            var di = dyn()->tu.nullable_inner(lt);
            if (di != &null) && (canon_unqual(di) == canon_unqual(rt)) { return canon_unqual(rt); }
            if (di != &null) && (canon_unqual(lt) == canon_unqual(rt)) { return canon_unqual(rt); }
        }
        // `a === b` in a generic body with a `T?` operand: bool whatever T
        // is, and the expansion's `==` on the values is the template's own
        // (C++ resolves it per instance, as for any `a == b` on a T). The
        // pointee rule is read off the types as written: `(*T)?` compares
        // pointees, a `T?` whose T turns out to be a pointer compares
        // addresses (NULLABLE.md 2.3 NOTE).
        if (k == TokenKind::OpEqualEqualEqual) && (self._is_dependent(lt) || self._is_dependent(rt))
        && ((dyn()->tu.nullable_inner(lt) != &null) || (dyn()->tu.nullable_inner(rt) != &null)) {
            if dyn()->tu.identity_derefs(lt, rt)
            && ((dyn()->tu.pointee(dyn()->tu.strip_nullable(lt)) == &null) || (dyn()->tu.pointee(dyn()->tu.strip_nullable(rt)) == &null)) {
                self._identity_not_pointers(n, lt, rt);
                return &null;
            }
            return dyn()->tu.builtin(BuiltinKind::Bool);
        }
        var own_op = (k != TokenKind::OpQuestionQuestion) && (k != TokenKind::OpEqualEqualEqual) && (k != TokenKind::KwIn);
        var bounded = own_op && self._bounded(lt);
        if (self._is_dependent(lt) || self._is_dependent(rt)) && (!bounded) {
            dyn()->mark_unknown(n);
            return &null;
        }

        // `??`
        if k == TokenKind::OpQuestionQuestion {
            var inner = dyn()->tu.nullable_inner(lt);
            if inner == &null {
                dyn()->warn(n, DiagID::SC065W, f"left operand of '??' has non-nullable type '{dyn()->tu.str(lt)}'; the right operand is never used");
                return lt;
            }
            // The result is the join of the arms of `if x? => x else y`
            // (NULLABLE.md 2.4): `T` when `y` is one, `T?` when `y` is (a
            // `T` arm joins a `T?` one as `T?`). Asked as written first, so
            // `(i32?)? ?? i32?` is `i32?`, the then-arm's own type; only
            // then with `y`'s nullable peeled and put back (`i32? ?? i64?`).
            var direct = dyn()->conv.join(inner, rt);
            if direct != &null { return direct; }
            var j = dyn()->conv.join(inner, dyn()->tu.strip_nullable(rt));
            if j == &null {
                dyn()->fail(n, DiagID::SC033E, f"'??' operands '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}' have no common type");
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
            // C++ operands get C++20's rewrite rule: a `!=` / `<` that cannot
            // take them yields to a derived one. Kairo's own rule derives only
            // when the type declares no `!=` at all.
            var cxx_rewrite = (self._is_inequality(k) || self._is_relational(k))
                           && (self._is_imported_record(lt) || self._is_imported_record(rt));
            var ut = self.resolve_user_op(static_cast::<*Expr>(n), k, TokenKind::TkUnknown, n->lhs, lt, rt,
                                          &args, -1, self._label(n->op_token), &found, cxx_rewrite);
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
            // Derived: `==` `!=` from `op <=>`, when no `op ==` answered
            // (`!=` tried it above): `(a <=> b) == 0`. Kairo's rule, not
            // C++20's -- C++ never derives equality from a user `<=>`, so an
            // imported record keeps exactly what C++ declares.
            if self._is_equality(k) && (!self._is_imported_record(lt)) && (!self._is_imported_record(rt)) {
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
            // Nothing in the bounds: deferred as any dependent operand is,
            // which is what it was before bounds were consulted.
            if bounded {
                dyn()->mark_unknown(n);
                return &null;
            }

            // No user operator. Equality is builtin on pointers, nullables and
            // plain enums; a record compares only through its own `op ==`, and
            // an ADT enum that declares none by its tags.
            if self._is_equality(k) {
                if self._is_plain_record(lt) || self._is_plain_record(rt) {
                    var rec = (lt) if (self._is_plain_record(lt)) else (rt);
                    dyn()->fail(n, DiagID::SC066E, f"no 'op ==' on '{dyn()->tu.str(rec)}'; a record compares only through its own operator");
                    return &null;
                }
                // Two values of one ADT: equal when their variants are. No
                // operator is bound; OperatorLowering compares the tags. lt and
                // rt are canonical and unqualified here, so one instance of a
                // generic enum is one pointer and two instances are two. A
                // nullable operand is no ADT to _adt_of and keeps the builtin
                // equality below.
                if (lt == rt) && (self._adt_of(lt) != &null) {
                    n->tag_eq = true;
                    return dyn()->tu.builtin(BuiltinKind::Bool);
                }
                if self.unify_operands(lt, rt) != &null { return dyn()->tu.builtin(BuiltinKind::Bool); }
            }
            dyn()->fail(n, DiagID::SC066E, f"no operator '{dyn()->sc->ctx->get_spelling(n->op_token)}' for operands '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}\x27");
            return &null;
        }

        // builtins
        if self._is_logical(k) {
            if (!dyn()->tu.is_bool(lt)) || (!dyn()->tu.is_bool(rt)) {
                dyn()->fail(n, DiagID::SC067E, "logical operators require 'bool' operands; use a comparison or an explicit cast");
                return &null;
            }
            return dyn()->tu.builtin(BuiltinKind::Bool);
        }
        if self._is_shift(k) {
            if (!dyn()->tu.is_integer(lt)) || (!dyn()->tu.is_integer(rt)) {
                dyn()->fail(n, DiagID::SC067E, "shift operands must be integers");
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
            dyn()->fail(n, DiagID::SC067E, f"bitwise operators require two integers, two bytes, or two bools, not '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}\x27");
            return &null;
        }
        if self._is_arith(k) {
            if (!dyn()->tu.is_numeric(lt)) || (!dyn()->tu.is_numeric(rt)) {
                dyn()->fail(n, DiagID::SC067E, f"arithmetic requires numeric operands, not '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}\x27");
                return &null;
            }
            var u = self.unify_operands(lt, rt);
            if u == &null { self._unify_error(n, lt, rt); return &null; }
            return u;
        }
        if self._is_equality(k) || self._is_relational(k) {
            if self._is_relational(k) && (!(dyn()->tu.is_numeric(lt) || dyn()->tu.is_builtin(lt, BuiltinKind::Char))) {
                dyn()->fail(n, DiagID::SC067E, f"ordering comparison is not defined on '{dyn()->tu.str(lt)}\x27");
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
            if ord == &null { dyn()->missing_lang_item(n, to_string(WellKnownType::Ordering)); return &null; }
            return ord;
        }
        dyn()->fail(n, DiagID::SC066E, f"operator '{dyn()->sc->ctx->get_spelling(n->op_token)}' is not defined on primitives");
        return &null;
    }

    /// What the right side of `x ?? y` is typed against: `x`'s `T`, the arm
    /// it joins (NULLABLE.md 2.4), so `f32? ?? 0.5` is `f32` and `u8? ?? 7`
    /// is `u8`, as `if x? => x else 7` would be. \p d for every other
    /// operator.
    priv fn _coalesce_down(self, k: TokenKind, lt: *Type, d: *Type) -> *Type {
        if k == TokenKind::OpEqualEqualEqual { return self._identity_down(lt, d); }
        if (k != TokenKind::OpQuestionQuestion) || (lt == &null) { return d; }
        var inner = dyn()->tu.nullable_inner(dyn()->tu.as_value(lt));
        if (inner == &null) || inner->is_dependent() { return d; }
        return inner;
    }

    /// What a literal on one side of `===` is typed against: the value the
    /// other side holds (`u8? === 7` compares two `u8`), the pointee when
    /// that is a nullable pointer (NULLABLE.md 2.3). \p d when \p other is
    /// not nullable.
    priv fn _identity_down(self, other: *Type, d: *Type) -> *Type {
        if other == &null { return d; }
        var inner = dyn()->tu.nullable_inner(dyn()->tu.as_value(other));
        if (inner == &null) || inner->is_dependent() { return d; }
        var p = dyn()->tu.pointee(inner);
        if p != &null { return d; }   // a literal is no pointer: the operands do not unify either way.
        return canon_unqual(inner);
    }

    /// The operators whose operands are read as values: everything but
    /// equality, `??`, `===` and `in` (and `^^`, typed on its own path).
    priv fn _reads_operands(self, k: TokenKind) -> bool {
        if self._is_equality(k) { return false; }
        if (k == TokenKind::OpQuestionQuestion) || (k == TokenKind::OpEqualEqualEqual) || (k == TokenKind::KwIn) { return false; }
        return self._is_arith(k) || self._is_bitwise(k) || self._is_shift(k) || self._is_logical(k)
            || self._is_relational(k) || (k == TokenKind::OpLessEqualGreater);
    }

    /// Both sides of `&&` / `||`, in order, the right one under the left's
    /// true set (`&&`) or false set (`||`); then the node's own sets for
    /// NullnessFlow::cond_of, and the state after it, their join. The
    /// right side of `t && y || z` is typed in a §4.1 trap, which decides
    /// whether its access errors get the parenthesizing fix-it.
    priv fn _type_logical_operands(self, n: *BinaryOperatorExpr) {
        var k = n->op_token.kind;
        var is_and = (k == TokenKind::OpAmpAmp) || (k == TokenKind::KwAnd);
        dyn()->type_of(n->lhs, &null);
        var cl = dyn()->flow.cond_of(n->lhs);
        dyn()->flow.env = (cl.t) if (is_and) else (cl.f);
        var trap = (!is_and) && dyn()->flow.trap_begin(n);
        dyn()->type_of(n->rhs, &null);
        if trap { dyn()->flow.trap_end(); }
        var cr = dyn()->flow.cond_of(n->rhs);
        var r = NullCond{};
        if is_and {
            r.t = cr.t;
            r.f = dyn()->flow.join(&(cl.f), &(cr.f));
        } else {
            r.t = dyn()->flow.join(&(cl.t), &(cr.t));
            r.f = cr.f;
        }
        dyn()->flow.env = dyn()->flow.join(&(r.t), &(r.f));
        dyn()->flow.store_cond(static_cast::<*Expr>(n), r);
    }

    /// The ADT enum a value of \p t is -- the pattern, for an instance of a
    /// generic one, as MatchLowering reaches it -- or null. \p t itself, not
    /// under a nullable: `Pt?` is no ADT here.
    priv fn _adt_of(self, t: *Type) -> *EnumDecl {
        var d = dyn()->tu.record_decl(t);
        if d == &null { return &null; }
        var en = dyn_cast::<EnumDecl>(decl_pattern(d));
        if (en == &null) || (!en->is_adt) { return &null; }
        return en;
    }

    priv fn _unify_error(self, n: *Expr, lt: *Type, rt: *Type) {
        dyn()->sc->diag->report(DiagID::SC033E, n->range.start,
            f"operands '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}' do not unify; neither converts implicitly to the other"
        ).first(n->range)
         .note(n->range.start, "cast one side explicitly with 'as' to choose the result type")
         .emit();
        n->poison();
    }

    /// `a === b`: both present and equal (NULLABLE.md 2.3), the `==` being
    /// the one the VALUES have. Needs a nullable operand. A nullable pointer
    /// compares what it points to (TypeUtil::identity_derefs), so then both
    /// sides must be pointers and their pointees are compared.
    ///
    /// The `==` is resolved HERE, on the unwrapped types, and recorded on
    /// this node (resolved_op / op_rewrite / tag_eq): CoalesceLowering
    /// builds the `a == b` of the expansion after typing, and OperatorLowering
    /// can only lower a `==` whose operator typing chose. Nothing after
    /// typing can bind a user `op ==`.
    priv fn _type_identity(self, n: *BinaryOperatorExpr, lt: *Type, rt: *Type) -> *Type {
        var ln = dyn()->tu.nullable_inner(lt);
        var rn = dyn()->tu.nullable_inner(rt);
        if (ln == &null) && (rn == &null) {
            dyn()->sc->diag->report(DiagID::SC034E, n->range.start,
                f"'===' needs a nullable operand; '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}' are not nullable"
            ).first(n->range)
             .note(n->range.start, "'===' is 'both present and equal'; on values that cannot be null it is '==\x27")
             .emit();
            n->poison();
            return &null;
        }
        var li = dyn()->tu.strip_nullable(lt);
        var ri = dyn()->tu.strip_nullable(rt);
        if dyn()->tu.identity_derefs(lt, rt) {
            var lp = dyn()->tu.pointee(li);
            var rp = dyn()->tu.pointee(ri);
            if (lp == &null) || (rp == &null) {
                self._identity_not_pointers(n, lt, rt);
                return &null;
            }
            if (dyn()->tu.is_unsafe_ptr(li) || dyn()->tu.is_unsafe_ptr(ri)) && (!dyn()->in_unsafe()) {
                dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                    f"'===' on '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}' dereferences a raw pointer, which requires an unsafe context"
                ).first(n->range)
                 .note(n->range.start, "write it inside 'unsafe { ... }', or compare the addresses with '==\x27")
                 .emit();
                n->poison();
                return &null;
            }
            li = lp;
            ri = rp;
        }
        if self._identity_eq(n, canon_unqual(li), canon_unqual(ri)) { return dyn()->tu.builtin(BuiltinKind::Bool); }
        return &null;
    }

    /// SC033E for `===` through a nullable pointer whose other side is no
    /// pointer: the pointees are what it compares (NULLABLE.md 2.3).
    priv fn _identity_not_pointers(self, n: *BinaryOperatorExpr, lt: *Type, rt: *Type) {
        dyn()->fail(n, DiagID::SC033E, f"'===' operands '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}' do not unify: on a nullable pointer '===' compares what it points to, so the other side must be a pointer too");
    }

    /// `x === null` / `null === x`: an error, since `===` is true only when
    /// both sides hold a value. The fix-it writes the null test it meant,
    /// `!x?`, when `x` is a name or a field path (anything else would need
    /// parentheses the fix-it cannot judge).
    priv fn _identity_null(self, n: *BinaryOperatorExpr, null_left: bool) -> *Type {
        var other = (n->rhs) if (null_left) else (n->lhs);
        if null_literal_of(other) == &null { dyn()->type_of(other, &null); }
        var b = dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
            "'===' with 'null' is never true: '===' holds only when both sides have a value");
        b.first(n->range);
        var x = dyn()->tu.strip_parens(other);
        if (x != &null) && (isa::<NamedIdentExpr>(x) || isa::<ChainExpr>(x)) {
            var sp = dyn()->sc->ctx->get_spelling(x->range);
            b.fix(n->range, f"!{sp}?", f"test '{sp}' for null");
        } else {
            b.note(n->range.start, "to test for null, write '!x?' (or 'x == null')");
        }
        b.emit();
        n->poison();
        return &null;
    }

    /// The `==` of `===`'s expansion, on the unwrapped types \p li / \p ri:
    /// the same answers `a == b` gets on two values (a user `op ==`, one
    /// derived from `op <=>`, an ADT's tag compare, builtin equality),
    /// recorded on \p n. False after reporting an error.
    priv fn _identity_eq(self, n: *BinaryOperatorExpr, li: *Type, ri: *Type) -> bool {
        var lb = dyn()->tu.kind_of(li) != BuiltinKind::COUNT;
        var rb = dyn()->tu.kind_of(ri) != BuiltinKind::COUNT;
        if lb && rb {
            if self.unify_operands(li, ri) != &null { return true; }
            dyn()->fail(n, DiagID::SC033E, f"'===' operands '{dyn()->tu.str(n->lhs->type_)}' and '{dyn()->tu.str(n->rhs->type_)}' do not unify");
            return false;
        }
        var found = false;
        var ut = self._identity_op(n, TokenKind::OpEqualEqual, li, ri, "op ==", &found);
        if found {
            if ut == &null { return false; }
            if !dyn()->tu.is_bool(ut) {
                dyn()->fail(n, DiagID::SC066E, f"'===' needs 'op ==' on '{dyn()->tu.str(li)}' to return 'bool', not '{dyn()->tu.str(ut)}\x27");
                return false;
            }
            return true;
        }
        // Derived from `op <=>`, Kairo's rule (see type_binary).
        if (!self._is_imported_record(li)) && (!self._is_imported_record(ri)) {
            ut = self._identity_op(n, TokenKind::OpLessEqualGreater, li, ri, "op <=>", &found);
            if found {
                if ut == &null { return false; }
                n->op_rewrite = OpRewrite::Cmp;
                return true;
            }
        }
        if self._is_plain_record(li) || self._is_plain_record(ri) {
            var rec = (li) if (self._is_plain_record(li)) else (ri);
            dyn()->fail(n, DiagID::SC066E, f"'===' compares the values with their 'op ==', and '{dyn()->tu.str(rec)}' has none");
            return false;
        }
        if (li == ri) && (self._adt_of(li) != &null) {
            n->tag_eq = true;
            return true;
        }
        if self.unify_operands(li, ri) != &null { return true; }
        dyn()->fail(n, DiagID::SC066E, f"'===' cannot compare '{dyn()->tu.str(li)}' with '{dyn()->tu.str(ri)}': there is no '==' for them");
        return false;
    }

    /// resolve_user_op for `===`'s `==`, against the UNWRAPPED operand types
    /// \p li / \p ri rather than the operands' own `T?`: the expansion
    /// compares the narrowed values. No argument is converted here (the
    /// operands are nullable; the values exist only in the expansion), so
    /// finish_call_args, whose check_convertible would read each `T?` as a
    /// value and report it may be null, is not run.
    priv fn _identity_op(self, n: *BinaryOperatorExpr, k: TokenKind, li: *Type, ri: *Type,
                         label: string, found: *bool) -> *Type {
        (*found) = false;
        var cands = vec::<*Decl>();
        var frees = vec::<*Decl>();
        self._gather(DeclName::op_name(k, TokenKind::TkUnknown), li, ri, -1, &cands, &frees);
        if (cands.size() == 0) && (frees.size() == 0) { return &null; }
        (*found) = true;
        var margs = vec::<ArgInfo>();
        var ra = self._typed_arg(n->rhs, ri);
        ra.cat = Expr::ValueCategory::LValue;   // the narrowed read is the place's value.
        margs.push_back(ra);
        var fargs = vec::<ArgInfo>();
        var la = self._typed_arg(n->lhs, li);
        la.cat = Expr::ValueCategory::LValue;
        fargs.push_back(la);
        fargs.push_back(ra);
        var r = dyn()->ovl.resolve_mixed(&cands, &margs, true, &frees, &fargs, n->range, label, li);
        if r.outcome == OvlOutcome::Dependent { dyn()->mark_unknown(n); return &null; }
        if r.outcome != OvlOutcome::Selected { dyn()->poison_only(n); return &null; }
        var rt = dyn()->call_result_type(r.decl, &r);
        self._record(static_cast::<*Expr>(n), static_cast::<*Decl>(r.decl), r.via_free, r.instance);
        return rt;
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
        dyn()->fail(n, DiagID::SC066E, f"'in' needs an 'op in' on '{dyn()->tu.str(rt)}' taking a '{dyn()->tu.str(lt)}\x27");
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
            dyn()->fail(n, DiagID::SC066E, f"no 'op ^^' on '{dyn()->tu.str(lt)}\x27");
            return &null;
        }
        if !dyn()->tu.is_numeric(lt) {
            dyn()->fail(n, DiagID::SC067E, f"'^^' needs a numeric base, not '{dyn()->tu.str(lt)}\x27");
            return &null;
        }
        if !dyn()->tu.is_integer(rt) {
            if dyn()->tu.is_float(rt) {
                dyn()->fail(n, DiagID::SC067E, f"the exponent of '^^' must be an integer, not '{dyn()->tu.str(rt)}'; a real exponent is a library function");
            } else {
                dyn()->fail(n, DiagID::SC067E, f"the exponent of '^^' must be an integer, not '{dyn()->tu.str(rt)}\x27");
            }
            return &null;
        }

        var d = dyn()->sc->well_known->get(WellKnownType::Pow);
        if d == &null { dyn()->missing_lang_item(n, to_string(WellKnownType::Pow)); return &null; }
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

    /// `unwrap!(x)`: `x`'s value, `T` for an `x: T?` (NULLABLE.md 2.6). It
    /// is not a read of `x` as `T` (§4), so `x` needs no check; it IS one
    /// afterwards, since on null the program has ended: `x` is non-null
    /// after it. An lvalue when `x` is a place, so `unwrap!(x).v = 1`
    /// writes `x`'s payload. Not a panic site. A dependent `T?` answers
    /// `T` now; any other dependent operand defers.
    fn type_unwrap(self, n: *UnwrapExpr, expected: *Type) -> *Type {
        if n->operand == &null { dyn()->poison_only(n); return &null; }
        var want: *Type = (dyn()->sc->types->nullable(canon_unqual(expected))) if ((expected != &null) && (dyn()->tu.nullable_inner(expected) == &null) && (!dyn()->tu.is_builtin(expected, BuiltinKind::Void))) else (&null);
        var ot = dyn()->type_of(n->operand, want);
        if dyn()->propagate(static_cast::<*Expr>(n), n->operand) { return &null; }
        if ot == &null { dyn()->mark_unknown(n); return &null; }
        var inner = dyn()->flow.narrowed_type(ot);
        if inner == &null {
            if self._is_dependent(ot) { dyn()->mark_unknown(n); return &null; }
            self._not_nullable_unwrap(n, dyn()->tu.as_value(ot));
            return &null;
        }
        var place = null_place_of(n->operand);
        if (place.size() > 0) && (n->operand->value_category == Expr::ValueCategory::LValue) {
            n->value_category = Expr::ValueCategory::LValue;
        } else {
            n->value_category = Expr::ValueCategory::RValue;
        }
        dyn()->flow.unwrapped(n->operand, n->range);
        return inner;
    }

    /// `unwrap!(x)` on an `x` that is never null: SC001E, with the fix-it
    /// that leaves `x` alone.
    priv fn _not_nullable_unwrap(self, n: *UnwrapExpr, ot: *Type) {
        var x  = dyn()->tu.strip_parens(n->operand);
        var id = (cast::<NamedIdentExpr>(x)) if ((x != &null) && isa::<NamedIdentExpr>(x)) else (&null);
        var text = dyn()->sc->ctx->get_spelling(n->operand->range);
        var b = dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
            f"'{text}' is not nullable ('{dyn()->tu.str(ot)}'); 'unwrap!' takes a nullable, and this value is never null");
        b.first(n->range);
        if (id != &null) && (id->resolved_decl != &null) {
            b.note(id->resolved_decl->range.start, f"'{text}' is declared '{dyn()->tu.str(ot)}' here");
        }
        b.remove(SourceRange(n->range.start, n->operand->range.start), "use the value as it is");
        b.remove(SourceRange(n->operand->range.end, n->range.end), "use the value as it is");
        b.emit();
        n->poison();
    }

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
                    dyn()->fail(n, DiagID::SC068E, f"cannot negate a literal of unsigned type '{dyn()->tu.str(t)}\x27");
                    return &null;
                }
                return t;
            }
        }

        var ot = dyn()->type_of(n->operand, self.cast_operand_expected(n->operand, (expected) if ((k == TokenKind::OpMinus) || (k == TokenKind::OpPlus) || (k == TokenKind::OpTilde)) else (&null)));
        if dyn()->propagate(n, n->operand) { return &null; }
        if ot == &null { return &null; }
        // `v.at(i)` is `i32&`; every arm below classifies the value it names,
        // and `&`/`*` want the referee too -- `&v.at(i)` is `*i32`, as in C++.
        // `&` keeps the lvalue's cv, though: as_value drops it, and taking the
        // address of a `const i32` must give `*const i32`, not a `*i32` that
        // launders the qualifier away.
        var place = ot;
        if isa::<CXXLValueRefType>(place)      { place = cast::<CXXLValueRefType>(place)->referee; }
        else if isa::<CXXRValueRefType>(place) { place = cast::<CXXRValueRefType>(place)->referee; }
        ot = dyn()->tu.as_value(ot);

        // `x?` on a nullable is the null test (NULLABLE.md 2.1), whatever
        // its inner: before the user-operator lookup, so a payload record's
        // own `op ?` never answers for its nullable, and before the
        // dependent deferral, so `t?` on a `T?` is `bool` in a generic body
        // too. Only the OUTER level is tested: `x?` on `(i32?)?` asks the
        // outer nullable. NullTestLowering lowers it (null_test_of).
        if (k == TokenKind::OpQuestion) && n->is_postfix() && (dyn()->tu.nullable_inner(ot) != &null) {
            return dyn()->tu.builtin(BuiltinKind::Bool);
        }

        // Every other operator but `&` reads its operand's value (NULLABLE.md
        // §4): `-a`, `*p`, `!b`, `++i` on a nullable place proven non-null
        // here act on the value; on one that is not, the nullness error.
        if (k != TokenKind::OpAmp) && (k != TokenKind::OpQuestion) && (k != TokenKind::OpEllipsis)
        && (dyn()->tu.nullable_inner(ot) != &null) {
            var nt = dyn()->read_value(n->operand);
            if nt == &null { dyn()->poison_only(n); return &null; }
            place = nt;
            if isa::<CXXLValueRefType>(place)      { place = cast::<CXXLValueRefType>(place)->referee; }
            else if isa::<CXXRValueRefType>(place) { place = cast::<CXXRValueRefType>(place)->referee; }
            ot = dyn()->tu.as_value(nt);
        }

        // user operator first for non-primitives. `++`/`--` keep only the
        // declared fixity that matches the use.
        if (dyn()->tu.kind_of(ot) == BuiltinKind::COUNT) && ((!self._is_dependent(ot)) || self._bounded(ot))
        && (k != TokenKind::OpAmp) && (k != TokenKind::OpStar) {
            var fix: i32 = -1;
            if (k == TokenKind::OpPlusPlus) || (k == TokenKind::OpMinusMinus) { fix = (1) if (n->is_postfix()) else (0); }
            var found = false;
            var args  = vec::<*Expr>();
            var ut = self.resolve_user_op(static_cast::<*Expr>(n), k, TokenKind::TkUnknown, n->operand, ot, &null,
                                          &args, fix, self._label(n->op_token), &found);
            if found { return ut; }
        }

        // Unary `*` is the pointer dereference and not overloadable in Kairo,
        // but a C++ class's `operator*` is how every C++ iterator and smart
        // pointer is read, so on an imported record it is looked up like any
        // other operator. Only there: a Kairo record's `op *` is the binary
        // one, and offering it to `*x` would turn "not a pointer" into a
        // misleading overload failure.
        if (k == TokenKind::OpStar) && (dyn()->tu.pointee(ot) == &null) && self._is_imported_record(ot) {
            var found = false;
            var args  = vec::<*Expr>();
            var ut = self.resolve_user_op(static_cast::<*Expr>(n), k, TokenKind::TkUnknown, n->operand, ot, &null,
                                          &args, -1, "operator*", &found);
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
                dyn()->fail(n, DiagID::SC067E, f"cannot negate a value of type '{dyn()->tu.str(ot)}\x27");
                return &null;
            }
            case TokenKind::OpPlus {
                if dyn()->tu.is_numeric(ot) { return canon_unqual(ot); }
                dyn()->fail(n, DiagID::SC067E, f"unary '+' requires a numeric operand, not '{dyn()->tu.str(ot)}\x27");
                return &null;
            }
            case TokenKind::OpTilde { return self._unary_bits(n, ot); }
            case TokenKind::KwCompl { return self._unary_bits(n, ot); }
            case TokenKind::OpAmp {
                if !dyn()->is_lvalue(n->operand) {
                    dyn()->fail(n, DiagID::SC069E, "cannot take the address of a temporary");
                    return &null;
                }
                // The pointer may write the place behind the analysis's back
                // until a consumer accounts for it (NULLABLE.md 3.4, 3.7).
                dyn()->flow.address_taken(n, place);
                return dyn()->sc->types->pointer(place, false);
            }
            case TokenKind::OpStar {
                dyn()->flow.consumed(n->operand);   // `*p` reads or writes where p points; no escape.
                var p = dyn()->tu.pointee(ot);
                if p == &null {
                    if dyn()->tu.nullable_inner(ot) != &null {
                        dyn()->fail(n, DiagID::SC070E, f"cannot dereference nullable '{dyn()->tu.str(ot)}'; check for null or use '?.\x27");
                    } else {
                        dyn()->fail(n, DiagID::SC070E, f"cannot dereference non-pointer type '{dyn()->tu.str(ot)}\x27");
                    }
                    return &null;
                }
                if dyn()->tu.is_void(p) { dyn()->fail(n, DiagID::SC070E, "cannot dereference '*void\x27"); return &null; }
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
            case TokenKind::OpQuestion {
                if n->is_postfix() { self._not_nullable_test(n, ot); return &null; }
                dyn()->fail(n, DiagID::SC066E, f"unary operator '?' is not defined on '{dyn()->tu.str(ot)}\x27");
                return &null;
            }
            default {
                dyn()->fail(n, DiagID::SC066E, f"unary operator '{dyn()->sc->ctx->get_spelling(n->op_token)}' is not defined on '{dyn()->tu.str(ot)}\x27");
                return &null;
            }
        }
    }

    /// `x == null` / `null != x` and the rest: \p lit the literal side,
    /// \p other the operand compared. Against a nullable it is the null
    /// test, `bool`, and the literal takes the nullable's type (so `&null`
    /// against a `(*T)?` is that nullable's null, 1.3, and `&null` against
    /// an `i32?` is the literal's own error). A dependent operand defers,
    /// as every operator on one does; a `T?` over a dependent T is still a
    /// nullable and answers now. Against a non-nullable, plain `null` is an
    /// error: the comparison could only be false (nullables.md: a `T` is
    /// never null), and C++ would not even accept it. `&null` against a
    /// non-nullable is not this test at all (`raw != &null` on an `unsafe
    /// *T` is a pointer comparison): `*done` stays false and the caller
    /// types the node as any other `==`; \p other's type is memoized.
    priv fn _type_null_compare(self, n: *BinaryOperatorExpr, lit: *NullLiteralExpr, other: *Expr, done: *bool) -> *Type {
        (*done) = true;
        var ot = dyn()->type_of(other, &null);
        if dyn()->propagate(n, other) { return &null; }
        if ot == &null { return &null; }
        var ov = dyn()->tu.as_value(ot);
        if dyn()->tu.nullable_inner(ov) != &null {
            var lt = dyn()->type_of(static_cast::<*Expr>(lit), canon_unqual(ov));
            if dyn()->propagate(n, static_cast::<*Expr>(lit)) || (lt == &null) { return &null; }
            return dyn()->tu.builtin(BuiltinKind::Bool);
        }
        if self._is_dependent(ov) {
            dyn()->mark_unknown(n);
            return &null;
        }
        if lit->is_ref { (*done) = false; return &null; }

        var x  = dyn()->tu.strip_parens(other);
        var id = (cast::<NamedIdentExpr>(x)) if ((x != &null) && isa::<NamedIdentExpr>(x)) else (&null);
        var what = ("the operand") if (id == &null) else (f"'{dyn()->sc->ctx->get_spelling(id->name)}\x27");
        // A raw pointer CAN be null, but its null is the pointer `&null`
        // (nullables.md, Pointers and nullability), and that comparison is
        // a real one: same mistake, different wording and an exact fix.
        if dyn()->tu.is_unsafe_ptr(ov) {
            var r = dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
                f"{what} is a raw pointer, not a nullable; a raw pointer's null is '&null\x27"
            );
            r.first(other->range);
            r.second(lit->range);
            r.fix(lit->range, "&null", "compare the pointer with '&null\x27");
            r.emit();
            n->poison();
            return &null;
        }
        var b = dyn()->sc->diag->report(DiagID::SC001E, n->range.start,
            f"{what} is not nullable; '{dyn()->tu.str(ov)}' is never null, so comparing it with 'null' is meaningless"
        );
        b.first(other->range);
        b.second(lit->range);
        if (id != &null) && (id->resolved_decl != &null) {
            b.note(id->resolved_decl->range.start, f"declared '{dyn()->tu.str(ov)}' here; a type that may be null is written 'T?\x27");
        }
        b.emit();
        n->poison();
        return &null;
    }

    /// `x?` on a value that cannot be null. SC066E (no operator for this
    /// operand type): `?` is the null test and has nothing to test on a
    /// `T`; a record's own `op ?` was already tried. No fix-it: dropping
    /// the `?` leaves a non-bool where a condition wanted one, and which
    /// test was meant is not knowable. The note points at the declaration
    /// that made it non-nullable, when the operand names one.
    priv fn _not_nullable_test(self, n: *UnaryOperatorExpr, ot: *Type) {
        if n->is_poisoned() { return; }
        var x  = dyn()->tu.strip_parens(n->operand);
        var id = (cast::<NamedIdentExpr>(x)) if ((x != &null) && isa::<NamedIdentExpr>(x)) else (&null);
        var what = ("the operand") if (id == &null) else (f"'{dyn()->sc->ctx->get_spelling(id->name)}\x27");
        var b = dyn()->sc->diag->report(DiagID::SC066E, n->range.start,
            f"{what} is not nullable; '?' tests a nullable, and '{dyn()->tu.str(ot)}' is never null"
        );
        b.first(n->range);
        if (id != &null) && (id->resolved_decl != &null) {
            b.note(id->resolved_decl->range.start, f"declared '{dyn()->tu.str(ot)}' here; a type that may be null is written 'T?\x27");
        }
        b.emit();
        n->poison();
    }

    priv fn _unary_bool(self, n: *UnaryOperatorExpr, ot: *Type) -> *Type {
        if dyn()->tu.is_bool(ot) { return canon_unqual(ot); }
        dyn()->fail(n, DiagID::SC067E, f"'!' requires a 'bool' operand, not '{dyn()->tu.str(ot)}\x27");
        return &null;
    }

    priv fn _unary_bits(self, n: *UnaryOperatorExpr, ot: *Type) -> *Type {
        if dyn()->tu.is_integer(ot) || dyn()->tu.is_builtin(ot, BuiltinKind::Byte) { return canon_unqual(ot); }
        dyn()->fail(n, DiagID::SC067E, f"'~' requires an integer or byte operand, not '{dyn()->tu.str(ot)}\x27");
        return &null;
    }

    priv fn _incdec(self, n: *UnaryOperatorExpr, ot: *Type) -> *Type {
        if !dyn()->tu.is_integer(ot) {
            var what = ("'++\x27") if (n->op_token.kind == TokenKind::OpPlusPlus) else ("'--\x27");
            if dyn()->tu.kind_of(ot) == BuiltinKind::COUNT {
                var fixname = ("r") if (n->is_postfix()) else ("l");
                dyn()->fail(n, DiagID::SC066E, f"no 'op {fixname}{dyn()->sc->ctx->get_spelling(n->op_token)}' on '{dyn()->tu.str(ot)}\x27");
                return &null;
            }
            dyn()->fail(n, DiagID::SC067E, f"{what} requires an integer operand, not '{dyn()->tu.str(ot)}\x27");
            return &null;
        }
        if !dyn()->is_lvalue(n->operand) {
            dyn()->fail(n, DiagID::SC071E, "'++'/'--' require an assignable operand");
            return &null;
        }
        if n->is_prefix() { n->value_category = Expr::ValueCategory::LValue; }
        return ot;
    }

    // === assignment =========================================================

    /// `self.f = e` directly in a constructor of f's record: for an array
    /// field this may be its initialization, which is no assignment, so the
    /// array rule (SC071E) is CtorInitCheck's to apply once it knows which
    /// write comes first. A closure in the constructor has a frame of its
    /// own, with no function, so its writes stay assignments.
    priv fn _ctor_field_write(self, n: *AssignOperatorExpr) -> bool {
        var fr = dyn()->cur_frame();
        if (fr == &null) || (fr->fn_decl == &null) { return false; }
        var fd = fr->fn_decl;
        if fd->is_operator || (!fd->is_method()) || (fd->adt_role != AdtRole::None) { return false; }
        var dc = reinterpret_cast::<*DeclContext>(fd->semantic_dc);
        if (dc == &null) || (!dc->is_type_scope()) || (dc->dc_owner == &null) { return false; }
        if dyn()->tu.decl_name(static_cast::<*Decl>(fd)) != dyn()->tu.decl_name(dc->dc_owner) { return false; }
        var c = dyn_cast::<ChainExpr>(n->lhs);
        if (c == &null) || (c->steps.size() != 1) { return false; }
        var ni = dyn_cast::<NamedIdentExpr>(c->base);
        if (ni == &null) || (ni->resolved_decl == &null) { return false; }
        var p = dyn_cast::<ParamDecl>(ni->resolved_decl);
        if (p == &null) || (!p->is_self) { return false; }
        var st = c->steps.get(0);
        if (st->resolved_decl == &null) || (!isa::<FieldDecl>(st->resolved_decl)) { return false; }
        var f = cast::<FieldDecl>(st->resolved_decl);
        return (!f->is_static()) && (f->semantic_dc == fd->semantic_dc);
    }

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
            dyn()->fail(n, DiagID::SC071E, "left side of assignment is not assignable");
            dyn()->type_of(n->rhs, &null);
            return &null;
        }

        if k == TokenKind::OpEqual {
            var lc = canon_unqual(lt);
            if (lc != &null) && isa::<FixedArrayType>(lc) && (!self._ctor_field_write(n)) {
                dyn()->type_of(n->rhs, lt);
                dyn()->fail(n, DiagID::SC071E, "an array is not assignable; assign its elements, or go through a slice");
                return &null;
            }
            dyn()->type_of(n->rhs, lt);
            if dyn()->propagate(n, n->rhs) { return &null; }
            if dyn()->reject_slice_literal(n->rhs, "assigned to a slice") { dyn()->poison_only(n); return &null; }
            if !dyn()->check_convertible(n->rhs, lt) { dyn()->poison_only(n); return &null; }
            n->value_category = Expr::ValueCategory::LValue;
            // The value SETS the place's state (NULLABLE.md 3.2).
            dyn()->flow.assign(n->lhs, n->rhs, n->range);
            return lt;
        }

        // compound: `a += b` reads both values (NULLABLE.md §4); a narrowed
        // `a` is written through, so it stays proven.
        if dyn()->tu.nullable_inner(lt) != &null {
            var nl = dyn()->read_value(n->lhs);
            if nl == &null { dyn()->poison_only(n); dyn()->type_of(n->rhs, &null); return &null; }
            lt = dyn()->tu.as_value(nl);
        }

        // compound: the underlying binary op's rules, converting the RIGHT
        // operand only (§6).
        var base = OperatorFacts::compound_base(k);
        var rt   = dyn()->type_of(n->rhs, lt);
        if dyn()->propagate(n, n->rhs) { return &null; }
        if rt == &null { return &null; }
        rt = dyn()->tu.as_value(rt);
        if dyn()->tu.nullable_inner(rt) != &null {
            var nr = dyn()->read_value(n->rhs);
            if nr == &null { dyn()->poison_only(n); return &null; }
            rt = dyn()->tu.as_value(nr);
        }
        // A bounded parameter on the left binds through its bounds, as in
        // the binary case; any other dependent operand defers.
        if (self._is_dependent(lt) || self._is_dependent(rt)) && (!self._bounded(lt)) { dyn()->mark_unknown(n); return &null; }

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
                dyn()->fail(n, DiagID::SC067E, "shift-assignment operands must be integers"); return &null;
            }
        } else if self._is_bitwise(base) {
            var ok = (dyn()->tu.is_integer(lt) && dyn()->tu.is_integer(rt))
                  || (dyn()->tu.is_bool(lt) && dyn()->tu.is_bool(rt))
                  || (dyn()->tu.is_builtin(lt, BuiltinKind::Byte) && dyn()->tu.is_builtin(rt, BuiltinKind::Byte));
            if !ok { dyn()->fail(n, DiagID::SC067E, f"bitwise assignment is not defined for '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}\x27"); return &null; }
            if !dyn()->check_convertible(n->rhs, lt) { dyn()->poison_only(n); return &null; }
        } else {
            if (!dyn()->tu.is_numeric(lt)) || (!dyn()->tu.is_numeric(rt)) {
                dyn()->fail(n, DiagID::SC067E, f"arithmetic assignment is not defined for '{dyn()->tu.str(lt)}' and '{dyn()->tu.str(rt)}\x27"); return &null;
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
            dyn()->sc->diag->report(DiagID::SC035E, n->range.start,
                f"both an 'op {bsp}' and its base operator apply to '{dyn()->tu.str(lt)}'; a type declares one and the other is derived from it"
            ).first(n->range).emit();
            n->poison();
            return &null;
        }
        if !(has_c || has_b) {
            if self._bounded(lt) { dyn()->mark_unknown(n); return &null; }   // nothing in the bounds: defer, as before.
            if !l_rec { return &null; }
            dyn()->fail(n, DiagID::SC066E, f"no operator '{dyn()->sc->ctx->get_spelling(n->op_token)}' on '{dyn()->tu.str(lt)}\x27");
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
                dyn()->fail(n, DiagID::SC072E, f"'op {dyn()->sc->ctx->get_spelling(n->op_token)}' derived from the base operator would assign a '{dyn()->tu.str(ut)}' to a '{dyn()->tu.str(lt)}\x27");
                return &null;
            }
        }
        n->value_category = Expr::ValueCategory::RValue;
        return dyn()->tu.builtin(BuiltinKind::Void);
    }
}