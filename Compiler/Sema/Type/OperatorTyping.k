/// --- The Kairo Project ------------------- Sema/Type/OperatorTyping.k --- ///
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
///     An operand with no type of its own -- an untyped literal, a list
///     literal, `.V` -- takes the other side's type (§5), on EITHER side:
///     the other operand is typed first. That is why `x + 1` and `1 + x`
///     work for any integer x with no conversion at all, and why `.North ==
///     d` is `d == .North`. A shift's literal left operand with no expected
///     type takes an integer count's type: `1 << 4u8` is a u8 shift.
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Context::DeclContext::DeclContext
import AST::Context::InstantiationRegistry::InstanceEntry
import AST::Context::SymbolTable::DeclName
import AST::DeclFacts::{
    decl_instantiated_from,
    decl_is_imported,
    decl_is_instance,
    decl_pattern,
}
import AST::Kind::DeclKind::to_string
import AST::Kind::ExprKind::{
    ExprKind,
    to_string,
}
import AST::LangItems::{
    WellKnownType,
    to_string,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    QUAL_CONST,
    RecordType,
    canon_has_const,
    canon_quals,
    canon_unqual,
    is_c_character,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    AdtRole,      ClassDecl, EnumDecl, FieldDecl, FunctionDecl, ParamDecl, StorageClass, StructDecl,
    UnionDecl,    VariableDecl,
}
import AST::Node::Expressions::{
    AssignOperatorExpr, BinaryOperatorExpr, OpRewrite, SubscriptExpr, TypeCastExpr, TypeOfExpr,
    UnaryOperatorExpr,  UnwrapExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    IntegerLiteralExpr,
    NamedIdentExpr,
    NullLiteralExpr,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    FixedArrayType,
}
import AST::OperatorFacts::OperatorFacts
import Diagnostic::Registry::DiagID
import Diagnostic::NoteText::named_declared_here
import Location::SourceRange::SourceRange
import Sema::Check::ConstEval::ConstEval
import Sema::Type::Conversion::ImplicitRank
import Sema::Type::NullnessFlow::{
    NULL_READ_NARROWED,
    NullCond,
    null_flow_type_is_nullable,
    null_literal_of,
    null_place_of,
}
import Sema::Type::OverloadResolution::{
    ArgInfo,
    LitKind,
    OvlOutcome,
}
import Sema::Type::Substitution::Substitution
import Token::Token::Token
import Token::TokenKind::{
    TokenKind,
    token_kind_to_readable_string,
}

// TODO(DUCK-GENERIC): T uses arg_info, call_result_type, check_convertible, conv, cur_frame, denoted_type, fail, finish, finish_call_args, flow, frames, in_unsafe, ... (32). Stage 0 was duck-typed; bound it or keep `: type`.
pub class <T: type> OperatorTyping {
    @move
    fn OperatorTyping(self, other: Self) = default
    fn OperatorTyping(self) = default
    priv inline fn dyn(self) -> unsafe *T {
        return unsafe ((&self) as *T)
    }

    /// # classification of the operator token

    priv fn _is_arith(self, k: TokenKind) -> bool {
        return k == TokenKind::OpPlus
            || k == TokenKind::OpMinus
            || k == TokenKind::OpStar
            || k == TokenKind::OpSlash
            || k == TokenKind::OpPercent
    }

    priv fn _is_bitwise(self, k: TokenKind) -> bool {
        return k == TokenKind::OpAmp
            || k == TokenKind::OpPipe
            || k == TokenKind::OpCaret
            || k == TokenKind::KwBitand
            || k == TokenKind::KwBitor
            || k == TokenKind::KwXor
    }

    priv fn _is_shift(self, k: TokenKind) -> bool {
        return k == TokenKind::OpLessLess || k == TokenKind::OpGreaterGreater
    }

    /// # shift counts (SHIFT spec §1, §4)

    /// The count of a builtin shift on integer \p lt, checked once its
    /// operands are typed. A count that evaluates at compile time must be in
    /// [0, W): past the width it is SC001E here, though at run time it would
    /// be taken modulo the register width -- a constant that large is a
    /// mistake, not a request for the modulo. Returns whether the count is
    /// proven in [0, W), which the caller records as no_wrap so EmitIR
    /// leaves the mask out: a constant, or `e & K` (0 <= K < W), or
    /// `e % K` (1 <= K <= W, e unsigned). Never reports on a poisoned node.
    priv fn _shift_count(self, n: unsafe *Expr, rhs: unsafe *Expr, lt: unsafe *Type) -> bool {
        var lv = self.dyn()->tu.as_value(lt)
        if lv == &null || !self.dyn()->tu.is_integer(lv) || lv->is_dependent() {
            return false
        }

        var w = self.dyn()->tu.int_bits(lv)
        if w == 0 || rhs == &null || rhs->is_poisoned() {
            return false
        }

        var ce = ConstEval(self.dyn()->sc)
        var c  = ce.eval_int(rhs)
        if c.ok {
            if !c.neg && !c.overflow && c.mag < (w as u64) {
                return true
            }

            var tn  = self.dyn()->tu.str(lv)
            var val = ce.str(c)
            var msg = f"shift count {val} is not below the width of '{tn}' ({w} bits)"
            if c.neg {
                msg = f"shift count {val} is negative; a constant count of a '{tn}' shift must be in 0..{w}"
            }

            var b = self.dyn()->sc->diag->report(DiagID::SC262E, rhs->range.start, msg)
            b.first(rhs->range, f"this count is {val}")
            var named = dyn_cast<NamedIdentExpr>(self.dyn()->tu.strip_parens(rhs))
            if named != &null
                && named->resolved_decl != &null
                && named->resolved_decl->range.is_valid() {
                b.note(
                    named->resolved_decl->range.start,
                    named_declared_here(self.dyn()->tu.decl_name(named->resolved_decl)),
                )
            }

            b.emit()
            n->poison()
            return false
        }

        var m = dyn_cast<BinaryOperatorExpr>(self.dyn()->tu.strip_parens(rhs))
        if m == &null || m->resolved_op != &null {
            return false
        }

        var mk = m->op_token.kind
        if mk == TokenKind::OpAmp || mk == TokenKind::KwBitand {
            var kr = ConstEval(self.dyn()->sc).eval_int(m->rhs)
            if !kr.ok {
                kr = ConstEval(self.dyn()->sc).eval_int(m->lhs)
            }

            return kr.ok && !kr.neg && !kr.overflow && kr.mag < (w as u64)
        }

        if mk == TokenKind::OpPercent {
            var et = self.dyn()->tu.as_value(m->lhs->type_)
            if et == &null || !self.dyn()->tu.is_integer(et) || self.dyn()->tu.is_signed_int(et) {
                return false
            }

            var kp = ConstEval(self.dyn()->sc).eval_int(m->rhs)
            return kp.ok && !kp.neg && !kp.overflow && kp.mag >= (1 as u64) && kp.mag <= (w as u64)
        }

        return false
    }

    priv fn _is_logical(self, k: TokenKind) -> bool {
        return k == TokenKind::OpAmpAmp
            || k == TokenKind::OpPipePipe
            || k == TokenKind::KwAnd
            || k == TokenKind::KwOr
    }

    priv fn _is_equality(self, k: TokenKind) -> bool {
        return k == TokenKind::OpEqualEqual
            || k == TokenKind::OpExclaimEqual
            || k == TokenKind::KwNotEq
    }

    priv fn _is_inequality(self, k: TokenKind) -> bool {
        return k == TokenKind::OpExclaimEqual || k == TokenKind::KwNotEq
    }

    priv fn _is_relational(self, k: TokenKind) -> bool {
        return k == TokenKind::OpLess
            || k == TokenKind::OpGreater
            || k == TokenKind::OpLessEqual
            || k == TokenKind::OpGreaterEqual
    }

    /// Dependent in either sense: a type mentioning a generic parameter, and
    /// one whose ARGUMENTS do. Both mean "not knowable until instantiation".
    priv fn _is_dependent(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        return t->is_dependent() || t->is_instantiation_dependent()
    }

    /// The interfaces a bounded generic parameter \p t promises, as their
    /// canonical instances (`T impl Same`, `T impl Container<U>`), or none
    /// when \p t is not a bare parameter or has no interface bound. An
    /// operator on such an operand is the bound's requirement, as a member
    /// call on it is (ChainBinding's dependent path): binding it here is what
    /// sends it through the interface's witness (Compiler/Spec/Witnesses.md#call-sites).
    /// MemberTyping's `op []` reads it too, so a subscript and a binary
    /// operator on one T see the same bounds.
    fn bound_ifaces(self, t: unsafe *Type) -> cxx::std::vector<unsafe *Type> {
        return Substitution(self.dyn()->sc).bound_ifaces(t)
    }

    /// Where a bounded parameter \p t's operators come from: bound_ifaces,
    /// then the bases its `derives` bounds name (Substitution::bound_scopes). A
    /// base's operator is an ordinary member, bound and emitted as one; an
    /// interface's is a requirement, called through the witness.
    fn bound_scopes(self, t: unsafe *Type) -> cxx::std::vector<unsafe *Type> {
        return Substitution(self.dyn()->sc).bound_scopes(t)
    }

    priv fn _bounded(self, t: unsafe *Type) -> bool {
        return self.bound_scopes(t).size() > 0
    }

    /// The requirement(s) that would give `sym` (an operator's spelling) on
    /// a bounds-checked parameter, as the derivations below try them:
    /// `!=` from `==`, a relational from `<=>`, `a + b` from `+=`.
    priv fn _granting(self, k: TokenKind, const sym: string) -> string {
        if self._is_inequality(k) {
            return f"'op {sym}' or 'op =='"
        }

        if self._is_relational(k) {
            return f"'op {sym}' or 'op <=>'"
        }

        if OperatorFacts::compound_of(k) != TokenKind::TkUnknown {
            return f"'op {sym}' or 'op {sym}='"
        }

        return f"'op {sym}'"
    }

    /// The D0 refusal of a binary operator touching a bounds-checked
    /// head that nothing granted it (TypeUtil::op_checked_head). The
    /// left operand's parameter is named: Kairo's operators are the left
    /// operand's. A parameter on the right of a CONCRETE left operand is
    /// refused too (`1 + t`: an `i32` has no `+` taking a T); one beside a
    /// dependent composite (`*T`, `Rep<T>`) is that composite's business
    /// and still defers. True after reporting.
    priv fn _refuse_checked(self,
                            n:  unsafe *BinaryOperatorExpr,
                            k:  TokenKind,
                            lt: unsafe *Type,
                            rt: unsafe *Type) -> bool {
        var sym     = self.dyn()->sc->ctx->get_spelling(n->op_token)
        var gl      = self.dyn()->tu.op_checked_head(lt)
        var gr      = self.dyn()->tu.op_checked_head(rt)
        var gp      = gl
        var bounded = gl != &null && self._bounded(lt)
        if gp == &null {
            if gr == &null || self._is_dependent(lt) {
                return false
            }

            gp = gr
            if self._bounded(rt) {
                self.dyn()->fail(
                    n,
                    DiagID::SC066E,
                    f"no operator '{sym}' for operands '{self.dyn()->tu.str(lt)}' and '{self.dyn()->tu.str(rt)}': an operator a bound grants is its parameter's, on the left",
                )

                return true
            }
        }

        if self._is_logical(k) {
            self.dyn()->fail(
                n,
                DiagID::SC067E,
                "logical operators require 'bool' operands; use a comparison or an explicit cast",
            )

            return true
        }

        var pname = self.dyn()->tu.head_spelling(if (gl != &null) => (lt) else => rt)
        self.dyn()->needs_bound(
            n,
            gp,
            bounded,
            f"'{sym}' on '{pname}' needs a bound that declares {self._granting(k, sym)}",
        )

        return true
    }

    /// A class, struct or union. Not an enum: a plain enum compares natively.
    priv fn _is_plain_record(self, t: unsafe *Type) -> bool {
        var d = self.dyn()->tu.record_decl(self.dyn()->tu.strip_nullable(t))
        if d == &null {
            return false
        }

        return isa<ClassDecl>(d) || isa<StructDecl>(d) || isa<UnionDecl>(d)
    }

    /// A record imported from a C++ header (not a Kairo one), or an instance
    /// of an imported template: `__wrap_iter<const int*>` is clang's
    /// instantiation, and only its primary carries the import stamp.
    priv fn _is_imported_record(self, t: unsafe *Type) -> bool {
        var d = self.dyn()->tu.record_decl(t)
        if d == &null {
            return false
        }

        if decl_is_imported(d) {
            return true
        }

        return decl_is_instance(d) && decl_is_imported(decl_instantiated_from(d))
    }

    /// \p t is an enum imported from C++. Its comparisons are C++'s
    /// built-in candidates, which compete with every operator ADL finds
    /// in its namespace; a user `operator==` template there that cannot take
    /// the enum is no reason to refuse `e == E::a`.
    priv fn _is_imported_enum(self, t: unsafe *Type) -> bool {
        var unsafe *c = canon_unqual(t)
        if c == &null || !isa<RecordType>(c) {
            return false
        }

        var unsafe *d = cast<RecordType>(c)->decl
        return d != &null && isa<EnumDecl>(d) && decl_is_imported(d)
    }

    priv fn _label(self, tok: Token) -> string {
        return "op " + self.dyn()->sc->ctx->get_spelling(tok)
    }

    /// §6 unification, or null. Operands are read as values; their
    /// top-level cv is gone by the time they meet.
    fn unify_operands(self, a_in: unsafe *Type, b_in: unsafe *Type) -> unsafe *Type {
        if a_in == &null || b_in == &null {
            return &null
        }

        var a = self.dyn()->tu.as_value(a_in)
        var b = self.dyn()->tu.as_value(b_in)
        if a == b {
            return a
        }

        // implicit_builtin: operands unify on the lattice, never through a
        // user's `@implicit op as` (see Conversion::join).
        var ab = self.dyn()->conv.implicit_builtin(a, b)
        var ba = self.dyn()->conv.implicit_builtin(b, a)
        if ab != ImplicitRank::None && ba == ImplicitRank::None {
            return b
        }

        if ba != ImplicitRank::None && ab == ImplicitRank::None {
            return a
        }

        return &null
    }

    /// # user operators: candidates

    /// The cv of the object \p t denotes: through any C++ reference (a
    /// reference is its referee), not through a pointer. MemberTyping reads a
    /// method call's receiver the same way.
    priv fn _object_quals(self, t: unsafe *Type) -> u8 {
        var unsafe *c = t
        while c != &null {
            if isa<CXXLValueRefType>(c) {
                c = cast<CXXLValueRefType>(c)->referee
                continue
            }

            if isa<CXXRValueRefType>(c) {
                c = cast<CXXRValueRefType>(c)->referee
                continue
            }

            break
        }

        return canon_quals(c)
    }

    /// The receiver OverloadResolution ranks `self` / `const self` against:
    /// the operand's value type carrying the object's cv. as_value() strips
    /// both, which is right for the result type and wrong here.
    priv fn _receiver_of(self, e: unsafe *Expr) -> unsafe *Type {
        if e == &null || e->type_ == &null {
            return &null
        }

        var q = self._object_quals(e->type_)
        var v = self.dyn()->tu.strip_nullable(self.dyn()->tu.as_value(e->type_))
        if v == &null {
            return &null
        }

        return self.dyn()->sc->types->qualified(v, q)
    }

    /// The scope an unqualified `op +` would be looked up from here: the
    /// enclosing function (an out-of-line body's is its owner's), else the TU.
    priv fn _use_site_scope(self) -> unsafe *DeclContext {
        var n = self.dyn()->frames.size()
        for var i: usize = 0; i < n; ++i {
            var fr = &self.dyn()->frames[n - 1 - i]
            // Typed local: `fr` is per instance (dyn()), so a cast straight off
            // fr->fn_decl is dependent once migrated and emits as a reinterpret,
            // which misses DeclContext's offset in FunctionDecl (its second base).
            var fdecl: unsafe *FunctionDecl = fr->fn_decl
            if fdecl != &null {
                return fdecl
            }
        }

        return self.dyn()->sc->tu
    }

    priv fn _has(self, const v: cxx::std::vector<unsafe *Decl>, d: unsafe *Decl) -> bool {
        for var i: usize = 0; i < v.size(); ++i {
            if (v)[i] == d {
                return true
            }
        }

        return false
    }

    /// Everything named \p name that applies with \p recv_ty as the receiver:
    /// members and extension members into \p cands, free operators into
    /// \p frees. \p other is the other operand's type or null. For `++`/`--`
    /// \p want_postfix (0 prefix, 1 postfix, -1 either) drops the wrong fixity:
    /// `op l++` and `op r++` share a cell and differ only there.
    priv fn _gather(self,
                    name:         DeclName,
                    recv_ty:      unsafe *Type,
                    other:        unsafe *Type,
                    want_postfix: i32,
                    cands:        unsafe *cxx::std::vector<unsafe *Decl>,
                    frees:        unsafe *cxx::std::vector<unsafe *Decl>) {
        // A bounded parameter offers its bounds' requirements and nothing
        // else: no ADL, no free operator, since neither can be known to apply
        // to every T the bound admits. A base's free operators are no
        // exception: they take the base by value, and a T does not slice
        // into one implicitly any more than a derived record does.
        var bound = self.bound_scopes(recv_ty)
        if bound.size() > 0 {
            for var i: usize = 0; i < bound.size(); ++i {
                self.dyn()->ml.lookup(bound[i], name, cands)
            }

            return
        }

        if recv_ty != &null {
            self.dyn()->ml.lookup(self.dyn()->tu.strip_nullable(recv_ty), name, cands)
        }

        // A C++ hidden friend sits in its class's table but is no member: it
        // takes every operand as an argument, and ADL reaches it through
        // EITHER operand's class (DeclImport::declare_friend).
        self._move_friends(&*cands, frees)
        if other != &null && self.dyn()->tu.record_decl(other) != &null {
            var theirs = cxx::std::vector<unsafe *Decl>()
            self.dyn()->ml.lookup(self.dyn()->tu.strip_nullable(other), name, &theirs)
            for var i: usize = 0; i < theirs.size(); ++i {
                var unsafe *f = dyn_cast<FunctionDecl>(theirs[i])
                if f == &null || f->is_method() {
                    continue
                }

                if self._has(*frees, theirs[i]) {
                    continue
                }

                frees->push_back(theirs[i])
            }
        }

        var scopes = cxx::std::vector<*DeclContext>()
        if recv_ty != &null {
            self.dyn()->ml.associated_scopes(recv_ty, &scopes)
            self.dyn()->ml.declaring_scope(recv_ty, &scopes)
        }

        if other != &null {
            self.dyn()->ml.associated_scopes(other, &scopes)
            self.dyn()->ml.declaring_scope(other, &scopes)
        }

        self.dyn()->ml.adl_candidates(&scopes, name, "", cands, frees)

        // The use site. A member reached this way (an operator of the
        // enclosing type, from inside one of its methods) already came through
        // ml.lookup if it applies; only free functions are new here.
        var r = self.dyn()->sc->lookup.unqualified(self._use_site_scope(), name)
        if r.found() {
            for var i: usize = 0; i < r.cell->size(); ++i {
                var d = r.cell->get(i)
                var f = dyn_cast<FunctionDecl>(d)
                if f == &null || f->is_method() {
                    continue
                }

                if self._has(*cands, d) || self._has(*frees, d) {
                    continue
                }

                frees->push_back(d)
            }
        }

        self._filter_free_applies(&*frees, recv_ty, other)

        if want_postfix < 0 {
            return
        }

        self._filter_fixity(&*cands, want_postfix == 1)
        self._filter_fixity(&*frees, want_postfix == 1)
    }

    /// Move the non-methods member lookup found (hidden friends) to \p frees.
    priv fn _move_friends(self,
                          @inout cands: cxx::std::vector<unsafe *Decl>,
                          frees:        unsafe *cxx::std::vector<unsafe *Decl>) {
        var keep = cxx::std::vector<unsafe *Decl>()
        for var i: usize = 0; i < cands.size(); ++i {
            var unsafe *f = dyn_cast<FunctionDecl>((cands)[i])
            if f != &null && !f->is_method() && decl_is_imported((cands)[i]) {
                if !self._has(*frees, (cands)[i]) {
                    frees->push_back((cands)[i])
                }

                continue
            }

            keep.push_back((cands)[i])
        }

        (cands) = keep
    }

    /// Drop the free operators that cannot take these operands at all. A
    /// free operator is reached by NAME from the use site, so `op +(F, F)`
    /// at file scope is in every `+`'s cell -- and a candidate that exists
    /// is what `found` means to every caller: it suppresses the derived
    /// forms, builtin enum equality, and makes `+=` beside a type's own
    /// `op +=` look like both halves of a pair. Arity and an implicit
    /// conversion per operand decide it; a dependent parameter is the
    /// instantiation's to decide, so it stays.
    priv fn _filter_free_applies(self,
                                 @inout v: cxx::std::vector<unsafe *Decl>,
                                 recv_ty:  unsafe *Type,
                                 other:    unsafe *Type) {
        // C++ looks an operator function up only when an operand has class
        // or enumeration type ([over.match.oper]/1): `p != nullptr` on two
        // pointers is the builtin, whatever ADL through `T*`'s namespace
        // would reach. Kept, clang's own free operator templates
        // (CustomizableOptional's `!=`) made `dyn_cast<TagDecl>(m) !=
        // &null` an SC063E with no viable candidate.
        var cxx_ok = self._class_or_enum(recv_ty) || self._class_or_enum(other)
        var keep   = cxx::std::vector<unsafe *Decl>()
        for var i: usize = 0; i < v.size(); ++i {
            var unsafe *f = dyn_cast<FunctionDecl>((v)[i])
            if f != &null && !cxx_ok && decl_is_imported((v)[i]) {
                continue
            }

            if f == &null || self._free_may_apply(f, recv_ty, other) {
                keep.push_back((v)[i])
            }
        }

        (v) = keep
    }

    /// \p t, references and nullability peeled, is a record or an enum: an
    /// operand that lets C++ consider operator functions at all.
    priv fn _class_or_enum(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var v = self.dyn()->tu.strip_nullable(self.dyn()->tu.as_value(t))
        if v == &null {
            return false
        }

        if v->is_dependent() {
            return true
        }

        return self.dyn()->tu.record_decl(v) != &null
    }

    priv fn _free_may_apply(self,
                            f:       unsafe *FunctionDecl,
                            recv_ty: unsafe *Type,
                            other:   unsafe *Type) -> bool {
        if f->is_variadic || f->generic_params.size() > 0 {
            return true
        }

        var want: usize = if (other != &null) => (2) else => 1
        if f->params.size() != want {
            return false
        }

        if !self._operand_fits(f->params[0], recv_ty) {
            return false
        }

        if other != &null && !self._operand_fits(f->params[1], other) {
            return false
        }

        return true
    }

    priv fn _operand_fits(self, p: unsafe *ParamDecl, t: unsafe *Type) -> bool {
        if p == &null || p->type_ == &null || p->type_->canonical == &null {
            return true
        }

        if t == &null || p->type_->is_dependent() {
            return true
        }

        var unsafe *pt = canon_unqual(p->type_->canonical)
        return self.dyn()->conv.implicit(
            canon_unqual(self.dyn()->tu.as_value(t)),
            pt,
        ) != ImplicitRank::None
    }

    priv fn _filter_fixity(self, @inout v: cxx::std::vector<unsafe *Decl>, postfix: bool) {
        var keep = cxx::std::vector<unsafe *Decl>()
        for var i: usize = 0; i < v.size(); ++i {
            var unsafe *f = dyn_cast<FunctionDecl>((v)[i])
            if f != &null && OperatorFacts::is_postfix(f) != postfix {
                continue
            }

            keep.push_back((v)[i])
        }

        (v) = keep
    }

    /// Record the winner on the operator node. OperatorLowering reads these
    /// and never looks an operator up again.
    priv fn _record(self, n: *Expr, d: unsafe *Decl, via_free: bool, inst: *InstanceEntry) {
        var unsafe *iv = unsafe (inst as unsafe *InstanceEntry)
        match n->kind {
            case ExprKind::BinaryOperatorExpr {
                var *b = cast<BinaryOperatorExpr>(n)
                b->resolved_op = d
                b->op_via_free = via_free
                b->op_instance = iv
            } case ExprKind::UnaryOperatorExpr {
                var *u = cast<UnaryOperatorExpr>(n)
                u->resolved_op = d
                u->op_via_free = via_free
                u->op_instance = iv
            } case ExprKind::AssignOperatorExpr {
                var *a = cast<AssignOperatorExpr>(n)
                a->resolved_op = d
                a->op_via_free = via_free
                a->op_instance = iv
            } default {
                kairo::std::ice_fail(
                    "OperatorTyping: _record on a node that carries no resolved_op",
                )
            }
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
    fn resolve_user_op(self,
                       n:            unsafe *Expr,
                       k0:           TokenKind,
                       k1:           TokenKind,
                       recv:         unsafe *Expr,
                       recv_ty:      unsafe *Type,
                       other:        unsafe *Type,
                       const args:   cxx::std::vector<unsafe *Expr>,
                       want_postfix: i32,
                       const label:  string,
                       found:        unsafe *bool,
                       viable_only:  bool = false,
                       copy_recv:    bool = false) -> unsafe *Type {
        *found = false
        if recv_ty == &null {
            return &null
        }

        var name  = DeclName::op_name(k0, k1)
        var cands = cxx::std::vector<unsafe *Decl>()
        var frees = cxx::std::vector<unsafe *Decl>()
        self._gather(name, recv_ty, other, want_postfix, unsafe &cands, unsafe &frees)
        if cands.size() == 0 && frees.size() == 0 {
            return &null
        }

        *found = true

        var margs = cxx::std::vector<ArgInfo>()
        for var i: usize = 0; i < args.size(); ++i {
            margs.push_back(self.dyn()->arg_info((args)[i]))
        }

        // A free operator takes the receiver operand as its first argument.
        var fargs = cxx::std::vector<ArgInfo>()
        fargs.push_back(self.dyn()->arg_info(recv))
        for var i: usize = 0; i < margs.size(); ++i {
            fargs.push_back(margs[i])
        }

        // \p copy_recv: the operator runs on a COPY of the receiver (a
        // derived `a + b` is `copy a, += b`), a fresh mutable value whatever
        // `a`'s own cv: a `const a: string` still adds.
        var unsafe *rcv = self._receiver_of(recv)
        if copy_recv && rcv != &null {
            rcv = canon_unqual(rcv)
        }

        if viable_only && !self.dyn()->ovl.any_viable(&cands, &margs, true, &frees, &fargs, rcv) {
            *found = false
            return &null
        }

        var r = self.dyn()->ovl.resolve_mixed(
            &cands,
            &margs,
            true,
            &frees,
            &fargs,
            n->range,
            label,
            rcv,
        )

        if r.outcome == OvlOutcome::Dependent {
            self.dyn()->mark_unknown(n)
            return &null
        }

        if r.outcome != OvlOutcome::Selected {
            self.dyn()->poison_only(n)
            return &null
        }

        self.dyn()->finish_call_args(r.decl, if (r.via_free) => (&fargs) else => &margs, &r)
        var rt = self.dyn()->call_result_type(r.decl, &r)
        self._record(n, r.decl, r.via_free, r.instance)
        return rt
    }

    /// An ArgInfo for an operand X already typed: never re-shaped as an
    /// untyped literal. `2.0 ^^ 3` with an expected f32 typed the base f32,
    /// and ranking its SHAPE would deduce the lang item's B as f64.
    priv fn _typed_arg(self, e: unsafe *Expr, t: unsafe *Type) -> ArgInfo {
        var a = self.dyn()->arg_info(e)
        a.lit       = LitKind::None
        a.ty        = t
        a.dependent = false
        return a
    }

    /// # binary

    /// \p t, unless \p e is a cast. A cast types its operand against its own
    /// target and never reads the expected type, so withholding it changes
    /// nothing but the redundant-cast lint: an operand is not a slot that
    /// already takes the source, and there the cast is what picks the width
    /// the operator runs at (`(b as u16) << 8`). See _lint_widening.
    fn cast_operand_expected(self, e: unsafe *Expr, t: unsafe *Type) -> unsafe *Type {
        if isa<TypeCastExpr>(self.dyn()->tu.strip_parens(e)) {
            return &null
        }

        return t
    }

    /// A left-leaning chain of one-line arithmetic or bitwise operators
    /// (`1 + 1 + 1 + ...`) recurses once per term through the left operand,
    /// and a few thousand terms overflow the stack (P804). Such an operator
    /// types its left operand first and hands it \p expected unchanged, so the
    /// chain is typed bottom-up here instead, in the order the recursion would
    /// have: each node's own typing then finds its left operand done.
    priv fn _prewarm_left_spine(self, n: unsafe *BinaryOperatorExpr, expected: unsafe *Type) {
        var spine = cxx::std::vector<unsafe *Expr>()
        var unsafe *cur = n->lhs
        while cur != &null && isa<BinaryOperatorExpr>(cur) && !self.dyn()->is_memoized(cur) {
            var ck = cast<BinaryOperatorExpr>(cur)->op_token.kind
            if !(self._is_arith(ck) || self._is_bitwise(ck)) {
                break
            }

            spine.push_back(cur)
            cur = cast<BinaryOperatorExpr>(cur)->lhs
        }

        // The innermost node's own left operand is no chain: its typing is
        // the ordinary (shallow) recursion.
        var i = spine.size()
        while i > 0 {
            i -= 1
            self.dyn()->type_of(spine[i], expected)
        }
    }

    fn type_binary(self, n: unsafe *BinaryOperatorExpr, expected: unsafe *Type) -> unsafe *Type {
        var k = n->op_token.kind

        if self._is_arith(k) || self._is_bitwise(k) {
            self._prewarm_left_spine(n, expected)
        }

        // `^^` types its operands independently, like a shift: the base takes
        // the expected type, the exponent is its own integer.
        if k == TokenKind::OpCaretCaret {
            return self._type_pow(n, expected)
        }

        // `typeof T == U` (Compiler/Spec/Eval.md "Type-based branching"): two types
        // compared, a compile-time bool. Asked before the operands are typed
        // as values: each would be "a type, not a value" (SC094E) and `typeof`
        // the TypeInfo value that does not exist yet (U001E).
        if k == TokenKind::OpEqualEqual
            || k == TokenKind::OpExclaimEqual
            || k == TokenKind::KwNotEq {
            if isa<TypeOfExpr>(n->lhs) || isa<TypeOfExpr>(n->rhs) {
                var lt = self.dyn()->denoted_type(n->lhs)
                var rt = self.dyn()->denoted_type(n->rhs)
                // Before propagate: a bare primitive operand is left "unknown"
                // on purpose (N does not bind it), which is not this node's.
                if lt != &null && rt != &null {
                    n->type_cmp_lhs   = if (lt->canonical != &null) => (lt->canonical) else => lt
                    n->type_cmp_rhs   = if (rt->canonical != &null) => (rt->canonical) else => rt
                    n->value_category = Expr::ValueCategory::RValue
                    return self.dyn()->tu.builtin(BuiltinKind::Bool)
                }

                if self.dyn()->propagate(n, n->lhs) || self.dyn()->propagate(n, n->rhs) {
                    return &null
                }
            }
        }

        // `x == null` and the other three spellings are the null test
        // (Compiler/Spec/Nullables.md#comparison-with-null). Asked before the operands are typed: a `null`
        // typed against a non-nullable would report "cannot infer the type
        // of null" and hide the real mistake.
        if self._is_equality(k) {
            var unsafe *nl = null_literal_of(n->lhs)
            var unsafe *nr = null_literal_of(n->rhs)
            if nl != &null != (nr != &null) {
                var done = false
                var unsafe *t = self._type_null_compare(
                    n,
                    if (nl != &null) => (nl) else => nr,
                    if (nl != &null) => (n->rhs) else => n->lhs,
                    unsafe &done,
                )

                if done {
                    return t
                }
            }
        }

        // `x === null` asks for both sides present, so it is never true: a
        // null test misspelled (Compiler/Spec/Nullables.md#identity). Before the operands are
        // typed, as for `== null`: the literal has nothing to take a type from.
        if k == TokenKind::OpEqualEqualEqual {
            var unsafe *nl = null_literal_of(n->lhs)
            var unsafe *nr = null_literal_of(n->rhs)
            if nl != &null || nr != &null {
                return self._identity_null(n, nl != &null)
            }
        }

        // `&&` / `||`: the right side runs only on one of the left side's
        // outcomes, so it is typed under that outcome's nullness facts
        // (Compiler/Spec/Nullables.md#definitions-and-conditions). Both sides are typed here, in order; the
        // operand typing below is then a memo hit.
        if self._is_logical(k) {
            self._type_logical_operands(n)
        }

        // `p == &null` on a safe `p` reads the literal as a `*T` it never
        // stores into: not the "`&null` in a `*T`" error (LiteralTyping).
        if self._is_equality(k) || self._is_relational(k) {
            var unsafe *cl = null_literal_of(n->lhs)
            if cl == &null {
                cl = null_literal_of(n->rhs)
            }

            if cl != &null && cl->is_ref {
                self.dyn()->null_compared = cl
            }
        }

        // An operand with no type of its own (an untyped literal, a list
        // literal, `.V`: ExprTyper::is_context_typed) takes the other's,
        // WHICHEVER side it is on: the other operand is typed first and its
        // type is the expected one, so `.North == d` is `d == .North` and
        // `[1, 2] == a` is `a == [1, 2]`. Typing order only: the operands
        // stay where they are and are evaluated left to right as written.
        // Both sides context-typed keep their defaults (`1 + 2` is i32).
        var l_lit              = self.dyn()->is_context_typed(n->lhs)
        var r_lit              = self.dyn()->is_context_typed(n->rhs)
        var lt:   unsafe *Type = &null
        var rt:   unsafe *Type = &null
        // Where the operands unify, so either one's type is the other's to
        // take. `<=>` is a comparison like the four relationals.
        var numeric_ctx = self._is_arith(k)
            || self._is_bitwise(k)
            || self._is_equality(k)
            || self._is_relational(k)
            || k == TokenKind::OpLessEqualGreater
        var pass_down: unsafe *Type = if (self._is_arith(k) || self._is_bitwise(k)) => (expected)
                                      else => &null
        // A shift's result IS its left operand's type, so the left operand
        // takes the expected type (`var m: u8 = 1 << 3` is a u8 shift, as `^^`'s
        // base is); the count stays its own integer.
        var lhs_down: unsafe *Type = if (self._is_shift(k)) => (expected) else => pass_down

        // The literal side takes the other side's VALUE type: a C++ element
        // read (`v[0] - 1` with `v[0]: u32&`) is a u32, and handed the
        // reference the literal stayed i32 and the pair did not unify.
        if l_lit && !r_lit {
            rt = self.dyn()->type_of(n->rhs, self.cast_operand_expected(n->rhs, pass_down))
            lt = self.dyn()->type_of(
                n->lhs,
                self._context_left_down(k, numeric_ctx, self._ref_value(rt), lhs_down),
            )
        } else if r_lit && !l_lit {
            lt = self.dyn()->type_of(n->lhs, self.cast_operand_expected(n->lhs, lhs_down))
            rt = self.dyn()->type_of(
                n->rhs,
                if (numeric_ctx) => (self._ref_value(lt))
                else => self._coalesce_down(k, lt, pass_down),
            )
        } else {
            lt = self.dyn()->type_of(n->lhs, self.cast_operand_expected(n->lhs, lhs_down))
            rt = self.dyn()->type_of(
                n->rhs,
                self.cast_operand_expected(
                    n->rhs,
                    if (numeric_ctx && pass_down == &null) => (lt)
                    else => self._coalesce_down(k, lt, pass_down),
                ),
            )
        }

        // `1 + P`: a type is no operand; both sides are reported.
        var tl = self.dyn()->reject_type_value(n->lhs)
        var tr = self.dyn()->reject_type_value(n->rhs)
        if tl || tr {
            self.dyn()->poison_only(n)
            return &null
        }

        if self.dyn()->propagate(n, n->lhs) || self.dyn()->propagate(n, n->rhs) {
            return &null
        }

        if lt == &null || rt == &null {
            return &null
        }

        // Every builtin result below is a prvalue; the user-operator path
        // reads the receiver's cv off the operand node itself.
        lt = self.dyn()->tu.as_value(lt)
        rt = self.dyn()->tu.as_value(rt)

        // A nullable operand of an operator that computes with it is a read
        // of its value (Compiler/Spec/Nullables.md#narrowed-reads): narrowed when its place is proven
        // non-null here, else the nullness error, never "no operator for
        // 'i32?'". `==` / `!=` compare nullables as they are (`a == 5` is
        // false on a null `a`), so they only take a proven value, when the
        // other side is no nullable; `??`, `===` and `in` take the nullable.
        if self._reads_operands(k) {
            if self.dyn()->tu.nullable_inner(lt) != &null {
                var nl = self.dyn()->read_value(n->lhs)
                if nl == &null {
                    self.dyn()->poison_only(n)
                    return &null
                }

                lt = self.dyn()->tu.as_value(nl)
            }

            if self.dyn()->tu.nullable_inner(rt) != &null {
                var nr = self.dyn()->read_value(n->rhs)
                if nr == &null {
                    self.dyn()->poison_only(n)
                    return &null
                }

                rt = self.dyn()->tu.as_value(nr)
            }
        } else if self._is_equality(k)
            && self.dyn()->tu.nullable_inner(lt) != &null != (self.dyn()->tu.nullable_inner(
                rt,
            ) != &null) {
            var unsafe *side = if (self.dyn()->tu.nullable_inner(lt) != &null) => (n->lhs)
                               else => n->rhs
            if self.dyn()->flow.read_value(side, false) == NULL_READ_NARROWED {
                lt = self.dyn()->tu.as_value(n->lhs->type_)
                rt = self.dyn()->tu.as_value(n->rhs->type_)
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
        if k == TokenKind::OpQuestionQuestion
            && (self._is_dependent(lt) || self._is_dependent(rt)) {
            var di = self.dyn()->tu.nullable_inner(lt)
            if di != &null && canon_unqual(di) == canon_unqual(rt) {
                return canon_unqual(rt)
            }

            if di != &null && canon_unqual(lt) == canon_unqual(rt) {
                return canon_unqual(rt)
            }
        }

        // `a === b` in a generic body with a `T?` operand: bool whatever T
        // is, and the expansion's `==` on the values is the template's own
        // (C++ resolves it per instance, as for any `a == b` on a T). The
        // pointee rule is read off the types as written: `(*T)?` compares
        // pointees, a `T?` whose T turns out to be a pointer compares
        // addresses (Compiler/Spec/Nullables.md#identity NOTE).
        // A value of a bounds-checked parameter is the exception (Compiler/Spec/Generics.md
        // D0): its `==` is whatever its bounds grant, so `===` takes the
        // ordinary path and asks them, and a T is never a pointer there.
        if k == TokenKind::OpEqualEqualEqual && (self._is_dependent(lt) || self._is_dependent(rt)) {
            var li = self.dyn()->tu.strip_nullable(lt)
            var ri = self.dyn()->tu.strip_nullable(rt)
            if self.dyn()->tu.identity_derefs(lt, rt)
                && self.dyn()->tu.pointee(li) != &null
                && self.dyn()->tu.pointee(ri) != &null {
                li = self.dyn()->tu.pointee(li)
                ri = self.dyn()->tu.pointee(ri)
            }

            if self.dyn()->tu.op_checked_head(li) != &null
                || self.dyn()->tu.op_checked_head(ri) != &null {
                return self._type_identity(n, lt, rt)
            }

            // Two operands that are never nullable whatever T is (a pointer,
            // a bounds-checked T): SC034E, as on any non-nullable pair.
            if self.dyn()->tu.nullable_inner(lt) == &null
                && self.dyn()->tu.nullable_inner(rt) == &null
                && (self.dyn()->tu.pointee(lt) != &null
                    || self.dyn()->tu.op_checked_head(lt) != &null)
                && (self.dyn()->tu.pointee(rt) != &null
                    || self.dyn()->tu.op_checked_head(rt) != &null) {
                return self._type_identity(n, lt, rt)
            }
        }

        if k == TokenKind::OpEqualEqualEqual
            && (self._is_dependent(lt) || self._is_dependent(rt))
            && (self.dyn()->tu.nullable_inner(lt) != &null
                || self.dyn()->tu.nullable_inner(rt) != &null) {
            if self.dyn()->tu.identity_derefs(lt, rt)
                && (self.dyn()->tu.pointee(self.dyn()->tu.strip_nullable(lt)) == &null
                    || self.dyn()->tu.pointee(self.dyn()->tu.strip_nullable(rt)) == &null) {
                self._identity_not_pointers(n, lt, rt)
                return &null
            }

            return self.dyn()->tu.builtin(BuiltinKind::Bool)
        }

        // Pointer arithmetic and ordering (pointers.mdx, Pointer Arithmetic)
        // are builtin, and ahead of the dependent deferral: `p + n` on an
        // `unsafe *T` is a pointer whatever T is, and C++ scales the offset
        // by sizeof T itself, so a generic body needs no instantiation to
        // type it. Any other shape falls through untouched.
        if self.dyn()->tu.pointee(lt) != &null && (self._is_arith(k) || self._is_relational(k)) {
            var        claimed = false
            var unsafe *pt     = self._type_pointer_op(n, k, lt, rt, unsafe &claimed)
            if claimed {
                return pt
            }
        }

        var own_op = k != TokenKind::OpQuestionQuestion
            && k != TokenKind::OpEqualEqualEqual
            && k != TokenKind::KwIn
        var bounded = own_op && self._bounded(lt)
        if (self._is_dependent(lt) || self._is_dependent(rt)) && !bounded {
            // Two values of one generic ADT instance whose enum declares no
            // `==`: the tag compare below needs nothing from the arguments
            // (EnumLayoutQuery reads a dependent layout's variant through
            // `__kairo_which()`), so it is the same answer in a generic body.
            if self._is_equality(k)
                && lt == rt
                && self._adt_of(lt) != &null
                && !self._declares_eq(lt) {
                n->tag_eq = true
                return self.dyn()->tu.builtin(BuiltinKind::Bool)
            }

            if own_op && self._refuse_checked(n, k, lt, rt) {
                return &null
            }

            self.dyn()->mark_unknown(n)
            return &null
        }

        // `??`
        if k == TokenKind::OpQuestionQuestion {
            var inner = self.dyn()->tu.nullable_inner(lt)
            if inner == &null {
                self.dyn()->warn(
                    n,
                    DiagID::SC065W,
                    f"left operand of '??' has non-nullable type '{self.dyn()->tu.str(lt)}'; the right operand is never used",
                )

                return lt
            }

            // The result is the join of the arms of `if x? => x else y`
            // (Compiler/Spec/Nullables.md#coalesce): `T` when `y` is one, `T?` when `y` is (a
            // `T` arm joins a `T?` one as `T?`). Asked as written first, so
            // `(i32?)? ?? i32?` is `i32?`, the then-arm's own type; only
            // then with `y`'s nullable peeled and put back (`i32? ?? i64?`).
            var direct = self.dyn()->conv.join(inner, rt)
            if direct != &null {
                return direct
            }

            var j = self.dyn()->conv.join(inner, self.dyn()->tu.strip_nullable(rt))
            if j == &null {
                self.dyn()->fail(
                    n,
                    DiagID::SC033E,
                    f"'??' operands '{self.dyn()->tu.str(lt)}' and '{self.dyn()->tu.str(rt)}' have no common type",
                )

                return &null
            }

            // T? ?? U?  stays nullable; T? ?? U collapses.
            return if (self.dyn()->tu.nullable_inner(
                       rt,
                   ) != &null) => (self.dyn()->sc->types->nullable(j))
                   else => j
        }

        if k == TokenKind::OpEqualEqualEqual {
            return self._type_identity(n, lt, rt)
        }

        if k == TokenKind::KwIn {
            return self._type_contains(n, lt, rt)
        }

        // user operator on a record / extended type.
        var lb = self.dyn()->tu.kind_of(lt) != BuiltinKind::COUNT
        var rb = self.dyn()->tu.kind_of(rt) != BuiltinKind::COUNT
        if !(lb && rb) {
            var found = false
            var args  = cxx::std::vector<unsafe *Expr>()
            args.push_back(n->rhs)
            // C++ operands get C++20's rewrite rule: a `!=` / `<` that cannot
            // take them yields to a derived one. Kairo's own rule derives only
            // when the type declares no `!=` at all.
            var cxx_rewrite = (self._is_inequality(k) || self._is_relational(k))
                && (self._is_imported_record(lt) || self._is_imported_record(rt))
            // A C++ enum operand: a non-viable ADL operator yields to the
            // built-in comparison below, as C++'s built-in candidates do.
            var cxx_enum = self._is_imported_enum(lt) || self._is_imported_enum(rt)
            var unsafe *ut = self.resolve_user_op(
                n,
                k,
                TokenKind::TkUnknown,
                n->lhs,
                lt,
                rt,
                args,
                -1,
                self._label(n->op_token),
                unsafe &found,
                cxx_rewrite || cxx_enum,
            )

            if found {
                return ut
            }

            // Derived: `!=` from `op ==`.
            if self._is_inequality(k) {
                ut = self.resolve_user_op(
                    n,
                    TokenKind::OpEqualEqual,
                    TokenKind::TkUnknown,
                    n->lhs,
                    lt,
                    rt,
                    args,
                    -1,
                    "op ==",
                    unsafe &found,
                    cxx_enum,
                )

                if found {
                    if ut == &null {
                        return &null
                    }

                    n->op_rewrite = OpRewrite::Not
                    return self.dyn()->tu.builtin(BuiltinKind::Bool)
                }
            }

            // Derived: `<` `<=` `>` `>=` from `op <=>`.
            if self._is_relational(k) {
                ut = self.resolve_user_op(
                    n,
                    TokenKind::OpLessEqualGreater,
                    TokenKind::TkUnknown,
                    n->lhs,
                    lt,
                    rt,
                    args,
                    -1,
                    "op <=>",
                    unsafe &found,
                    cxx_enum,
                )

                if found {
                    if ut == &null {
                        return &null
                    }

                    n->op_rewrite = OpRewrite::Cmp
                    return self.dyn()->tu.builtin(BuiltinKind::Bool)
                }
            }

            // Derived: `==` `!=` from `op <=>`, when no `op ==` answered
            // (`!=` tried it above): `(a <=> b) == 0`. Kairo's rule, not
            // C++20's -- C++ never derives equality from a user `<=>`, so an
            // imported record keeps exactly what C++ declares.
            if self._is_equality(k)
                && !self._is_imported_record(lt)
                && !self._is_imported_record(rt) {
                ut = self.resolve_user_op(
                    n,
                    TokenKind::OpLessEqualGreater,
                    TokenKind::TkUnknown,
                    n->lhs,
                    lt,
                    rt,
                    args,
                    -1,
                    "op <=>",
                    unsafe &found,
                )

                if found {
                    if ut == &null {
                        return &null
                    }

                    n->op_rewrite = OpRewrite::Cmp
                    return self.dyn()->tu.builtin(BuiltinKind::Bool)
                }
            }

            // Derived: `a + b` from `op +=` -- copy a, `+=` b, yield the copy.
            // The node's type is the LHS's, not the call's (void).
            var ck = OperatorFacts::compound_of(k)
            if ck != TokenKind::TkUnknown && !decl_is_imported(self.dyn()->tu.record_decl(lt)) {
                ut = self.resolve_user_op(
                    n,
                    ck,
                    TokenKind::TkUnknown,
                    n->lhs,
                    lt,
                    rt,
                    args,
                    -1,
                    self._label(n->op_token),
                    unsafe &found,
                    false,
                    true,
                )

                if found {
                    // Bound or not is resolved_op, set only on Selected: the
                    // node's dependence flags are its OPERANDS' too
                    // (propagate), so a `T` left operand whose bound declares
                    // `op +=` would read as deferred and leave the node
                    // untyped for _derived_sum.
                    if n->is_poisoned() || n->resolved_op == &null {
                        return &null
                    }

                    return canon_unqual(lt)
                }
            }

            // Nothing in the bounds: an error on a bounds-checked parameter
            // (D0: the bounds are all it has), else deferred as any
            // dependent operand is.
            if bounded {
                if self._refuse_checked(n, k, lt, rt) {
                    return &null
                }

                self.dyn()->mark_unknown(n)
                return &null
            }

            // No user operator. Equality is builtin on pointers, nullables and
            // plain enums; a record compares only through its own `op ==`, and
            // an ADT enum that declares none by its tags.
            if self._is_equality(k) {
                if self._is_plain_record(lt) || self._is_plain_record(rt) {
                    var unsafe *rec = if (self._is_plain_record(lt)) => (lt) else => rt
                    self.dyn()->fail(
                        n,
                        DiagID::SC066E,
                        f"no 'op ==' on '{self.dyn()->tu.str(rec)}'; a record compares only through its own operator",
                    )

                    return &null
                }

                // Two values of one ADT: equal when their variants are. No
                // operator is bound; OperatorLowering compares the tags. lt and
                // rt are canonical and unqualified here, so one instance of a
                // generic enum is one pointer and two instances are two. A
                // nullable operand is no ADT to _adt_of and keeps the builtin
                // equality below.
                if lt == rt && self._adt_of(lt) != &null {
                    n->tag_eq = true
                    return self.dyn()->tu.builtin(BuiltinKind::Bool)
                }

                if self.unify_operands(lt, rt) != &null {
                    return self.dyn()->tu.builtin(BuiltinKind::Bool)
                }
            }

            self.dyn()->fail(
                n,
                DiagID::SC066E,
                f"no operator '{self.dyn()->sc->ctx->get_spelling(n->op_token)}' for operands '{self.dyn()->tu.str(lt)}' and '{self.dyn()->tu.str(rt)}'",
            )

            return &null
        }

        // builtins
        if self._is_logical(k) {
            if !self.dyn()->tu.is_bool(lt) || !self.dyn()->tu.is_bool(rt) {
                self.dyn()->fail(
                    n,
                    DiagID::SC067E,
                    "logical operators require 'bool' operands; use a comparison or an explicit cast",
                )

                return &null
            }

            return self.dyn()->tu.builtin(BuiltinKind::Bool)
        }

        if self._is_shift(k) {
            if !self.dyn()->tu.is_integer(lt) || !self.dyn()->tu.is_integer(rt) {
                self.dyn()->fail(n, DiagID::SC067E, "shift operands must be integers")
                return &null
            }

            n->no_wrap = self._shift_count(n, n->rhs, lt)
            if n->is_poisoned() {
                return &null
            }

            return lt
        }

        if self._is_bitwise(k) {
            if self.dyn()->tu.is_bool(lt) && self.dyn()->tu.is_bool(rt) {
                return lt
            }

            if self.dyn()->tu.is_builtin(lt, BuiltinKind::Byte)
                && self.dyn()->tu.is_builtin(rt, BuiltinKind::Byte) {
                return lt
            }

            if self.dyn()->tu.is_integer(lt) && self.dyn()->tu.is_integer(rt) {
                var unsafe *u = self.unify_operands(lt, rt)
                if u == &null {
                    self._unify_error(n, lt, rt)
                    return &null
                }

                return u
            }

            self.dyn()->fail(
                n,
                DiagID::SC067E,
                f"bitwise operators require two integers, two bytes, or two bools, not '{self.dyn()->tu.str(lt)}' and '{self.dyn()->tu.str(rt)}'",
            )

            return &null
        }

        if self._is_arith(k) {
            if !self.dyn()->tu.is_numeric(lt) || !self.dyn()->tu.is_numeric(rt) {
                self.dyn()->fail(
                    n,
                    DiagID::SC067E,
                    f"arithmetic requires numeric operands, not '{self.dyn()->tu.str(lt)}' and '{self.dyn()->tu.str(rt)}'",
                )

                return &null
            }

            var unsafe *u = self.unify_operands(lt, rt)
            if u == &null {
                self._unify_error(n, lt, rt)
                return &null
            }

            return u
        }

        if self._is_equality(k) || self._is_relational(k) {
            if self._is_relational(k)
                && !(self.dyn()->tu.is_numeric(lt)
                    || self.dyn()->tu.is_builtin(lt, BuiltinKind::Char)
                    || is_c_character(self.dyn()->tu.kind_of(lt))) {
                self.dyn()->fail(
                    n,
                    DiagID::SC067E,
                    f"ordering comparison is not defined on '{self.dyn()->tu.str(lt)}'",
                )

                return &null
            }

            var unsafe *u = self.unify_operands(lt, rt)
            if u == &null {
                self._unify_error(n, lt, rt)
                return &null
            }

            return self.dyn()->tu.builtin(BuiltinKind::Bool)
        }

        if k == TokenKind::OpLessEqualGreater {
            var unsafe *u = self.unify_operands(lt, rt)
            if u == &null {
                self._unify_error(n, lt, rt)
                return &null
            }

            var a   = cxx::std::vector<*Type>()
            var ord = self.dyn()->tu.lang_record(WellKnownType::Ordering, &a)
            if ord == &null {
                self.dyn()->missing_lang_item(n, to_string(WellKnownType::Ordering))
                return &null
            }

            return ord
        }

        self.dyn()->fail(
            n,
            DiagID::SC066E,
            f"operator '{self.dyn()->sc->ctx->get_spelling(n->op_token)}' is not defined on primitives",
        )

        return &null
    }

    /// What a context-typed LEFT operand is typed against, the right one
    /// \p rt already typed. Where operands unify (arithmetic, bitwise,
    /// comparison) it is \p rt, as a context-typed right operand gets the
    /// left's. `===` reads through the nullable (_identity_down). A shift's
    /// result is its left operand's type, so the expected type \p d decides
    /// it when there is one (`var m: u16 = 1 << s`); without one, an integer
    /// count does (`1 << 4u8` is a u8 shift, USER 2026-10-28), never a
    /// default i32 the count says nothing about. `??` and `in`: \p d.
    priv fn _context_left_down(self,
                               k:           TokenKind,
                               numeric_ctx: bool,
                               rt:          unsafe *Type,
                               d:           unsafe *Type) -> unsafe *Type {
        if numeric_ctx {
            return rt
        }

        if k == TokenKind::OpEqualEqualEqual {
            return self._identity_down(rt, d)
        }

        if self._is_shift(k)
            && d == &null
            && rt != &null
            && self.dyn()->tu.is_integer(self.dyn()->tu.as_value(rt)) {
            return canon_unqual(self.dyn()->tu.as_value(rt))
        }

        return d
    }

    /// What the right side of `x ?? y` is typed against: `x`'s `T`, the arm
    /// it joins (Compiler/Spec/Nullables.md#coalesce), so `f32? ?? 0.5` is `f32` and `u8? ?? 7`
    /// is `u8`, as `if x? => x else 7` would be. \p d for every other
    /// operator.
    priv fn _coalesce_down(self, k: TokenKind, lt: unsafe *Type, d: unsafe *Type) -> unsafe *Type {
        if k == TokenKind::OpEqualEqualEqual {
            return self._identity_down(lt, d)
        }

        if k != TokenKind::OpQuestionQuestion || lt == &null {
            return d
        }

        var inner = self.dyn()->tu.nullable_inner(self.dyn()->tu.as_value(lt))
        if inner == &null || inner->is_dependent() {
            return d
        }

        return inner
    }

    /// What a literal on one side of `===` is typed against: the value the
    /// other side holds (`u8? === 7` compares two `u8`), the pointee when
    /// that is a nullable pointer (Compiler/Spec/Nullables.md#identity). \p d when \p other is
    /// not nullable.
    priv fn _identity_down(self, other: unsafe *Type, d: unsafe *Type) -> unsafe *Type {
        if other == &null {
            return d
        }

        var inner = self.dyn()->tu.nullable_inner(self.dyn()->tu.as_value(other))
        if inner == &null || inner->is_dependent() {
            return d
        }

        var p = self.dyn()->tu.pointee(inner)
        if p != &null { // a literal is no pointer: the operands do not unify either way.
            return d
        }

        return canon_unqual(inner)
    }

    /// The operators whose operands are read as values: everything but
    /// equality, `??`, `===` and `in` (and `^^`, typed on its own path).
    priv fn _reads_operands(self, k: TokenKind) -> bool {
        if self._is_equality(k) {
            return false
        }

        if k == TokenKind::OpQuestionQuestion
            || k == TokenKind::OpEqualEqualEqual
            || k == TokenKind::KwIn {
            return false
        }

        return self._is_arith(k)
            || self._is_bitwise(k)
            || self._is_shift(k)
            || self._is_logical(k)
            || self._is_relational(k)
            || k == TokenKind::OpLessEqualGreater
    }

    /// Both sides of `&&` / `||`, in order, the right one under the left's
    /// true set (`&&`) or false set (`||`); then the node's own sets for
    /// NullnessFlow::cond_of, and the state after it, their join. The
    /// right side of `t && y || z` is typed in a §4.1 trap, which decides
    /// whether its access errors get the parenthesizing fix-it.
    priv fn _type_logical_operands(self, n: unsafe *BinaryOperatorExpr) {
        var k      = n->op_token.kind
        var is_and = k == TokenKind::OpAmpAmp || k == TokenKind::KwAnd
        self.dyn()->type_of(n->lhs, &null)
        var cl = self.dyn()->flow.cond_of(n->lhs)
        self.dyn()->flow.env = if (is_and) => (cl.t) else => cl.f
        var trap = !is_and && self.dyn()->flow.trap_begin(n)
        self.dyn()->type_of(n->rhs, &null)
        if trap {
            self.dyn()->flow.trap_end()
        }

        var cr = self.dyn()->flow.cond_of(n->rhs)
        var r  = NullCond{}
        if is_and {
            r.t = cr.t
            r.f = self.dyn()->flow.join(&cl.f, &cr.f)
        } else {
            r.t = self.dyn()->flow.join(&cl.t, &cr.t)
            r.f = cr.f
        }

        self.dyn()->flow.env = self.dyn()->flow.join(&r.t, &r.f)
        self.dyn()->flow.store_cond(n, r)
    }

    /// The ADT enum a value of \p t is -- the pattern, for an instance of a
    /// generic one, as MatchLowering reaches it -- or null. \p t itself, not
    /// under a nullable: `Pt?` is no ADT here.
    /// Anything named `op ==` or `op <=>` applies to \p t: the user
    /// operators an ADT's `==` would bind before its tag compare.
    priv fn _declares_eq(self, t: unsafe *Type) -> bool {
        var c = cxx::std::vector<unsafe *Decl>()
        var f = cxx::std::vector<unsafe *Decl>()
        self._gather(
            DeclName::op_name(TokenKind::OpEqualEqual, TokenKind::TkUnknown),
            t,
            t,
            -1,
            unsafe &c,
            unsafe &f,
        )

        self._gather(
            DeclName::op_name(TokenKind::OpLessEqualGreater, TokenKind::TkUnknown),
            t,
            t,
            -1,
            unsafe &c,
            unsafe &f,
        )

        return c.size() > 0 || f.size() > 0
    }

    priv fn _adt_of(self, t: unsafe *Type) -> unsafe *EnumDecl {
        var d = self.dyn()->tu.record_decl(t)
        if d == &null {
            return &null
        }

        var en = dyn_cast<EnumDecl>(decl_pattern(d))
        if en == &null || !en->is_adt {
            return &null
        }

        return en
    }

    /// \p a and \p b are one pointer type up to the pointee's cv: the
    /// same kind (safe or raw) and the same pointee. What C++ takes for
    /// `<` and `-` on pointers (the composite pointer type), so `*const T`
    /// orders against `*T`; a safe pointer never meets a raw one silently.
    priv fn _same_pointer(self, a: unsafe *Type, b: unsafe *Type) -> bool {
        var pa = self.dyn()->tu.pointee(a)
        var pb = self.dyn()->tu.pointee(b)
        if pa == &null || pb == &null {
            return false
        }

        if self.dyn()->tu.is_unsafe_ptr(a) != self.dyn()->tu.is_unsafe_ptr(b) {
            return false
        }

        return canon_unqual(pa) == canon_unqual(pb)
    }

    /// The builtin operators on a pointer left operand \p lt:
    ///   `p + n`, `p - n`  any integer n, the pointer moved n * sizeof T --
    ///                     C++'s own pointer arithmetic, so `unsafe *u8 +
    ///                     usize` is byte arithmetic. Both pointer kinds
    ///                     (Tether bounds-checks the safe one's offset).
    ///   `p - q`           isize, the distance in Ts; raw pointers only. A
    ///                     safe pointer's provenance is one allocation and
    ///                     Tether checks an offset, never a difference, so
    ///                     pointers.mdx sends `p1 - p2` to `unsafe *T`.
    ///   `<` `<=` `>` `>=` bool, two pointers of one type, either kind.
    /// \p claimed false leaves the pair to the paths after (a dependent or
    /// record right operand). EmitIR spells all of them as C++'s operator:
    /// no pointer type has a wrap form (EmitIR::_wraps).
    priv fn _type_pointer_op(self,
                             n:       unsafe *BinaryOperatorExpr,
                             k:       TokenKind,
                             lt:      unsafe *Type,
                             rt:      unsafe *Type,
                             claimed: unsafe *bool) -> unsafe *Type {
        var plus_minus = k == TokenKind::OpPlus || k == TokenKind::OpMinus
        var r_ptr      = self.dyn()->tu.pointee(rt) != &null
        if plus_minus && self.dyn()->tu.is_integer(rt) {
            *claimed = true
            if self.dyn()->tu.is_void(self.dyn()->tu.pointee(lt)) {
                self.dyn()->fail(
                    n,
                    DiagID::SC067E,
                    f"pointer arithmetic moves in units of the pointee, and '{self.dyn()->tu.str(lt)}' points to void; cast it to a typed pointer first",
                )

                return &null
            }

            return canon_unqual(lt)
        }

        if k == TokenKind::OpMinus && r_ptr {
            *claimed = true
            if !self.dyn()->tu.is_unsafe_ptr(lt) || !self.dyn()->tu.is_unsafe_ptr(rt) {
                self.dyn()->fail(
                    n,
                    DiagID::SC067E,
                    f"the difference of two pointers is defined on raw pointers only, not '{self.dyn()->tu.str(lt)}' and '{self.dyn()->tu.str(rt)}'; a safe pointer takes an integer offset, so convert both with 'as unsafe *T' for a distance",
                )

                return &null
            }

            if self.dyn()->tu.is_void(self.dyn()->tu.pointee(lt)) {
                self.dyn()->fail(
                    n,
                    DiagID::SC067E,
                    f"a pointer difference counts pointees, and '{self.dyn()->tu.str(lt)}' points to void; cast both to a typed pointer first",
                )

                return &null
            }

            if !self._same_pointer(lt, rt) {
                self._unify_error(n, lt, rt)
                return &null
            }

            return self.dyn()->tu.builtin(BuiltinKind::ISize)
        }

        if self._is_relational(k) && r_ptr {
            *claimed = true
            if !self._same_pointer(lt, rt) {
                self._unify_error(n, lt, rt)
                return &null
            }

            return self.dyn()->tu.builtin(BuiltinKind::Bool)
        }

        return &null
    }

    /// \p t, or its referee when it is a C++ reference.
    priv fn _ref_value(self, t: unsafe *Type) -> unsafe *Type {
        var unsafe *c = canon_unqual(t)
        if c != &null && (isa<CXXLValueRefType>(c) || isa<CXXRValueRefType>(c)) {
            return self.dyn()->tu.as_value(c)
        }

        return t
    }

    priv fn _unify_error(self, n: unsafe *Expr, lt: unsafe *Type, rt: unsafe *Type) {
        // Two concrete types that do not unify fail in every instance: in a
        // generic `eval if typeof T == U` branch (typed once, diagnostics
        // dropped) the error still has to surface, or the poisoned node
        // reaches codegen unexplained.
        var lifted: u32 = 0
        var lift = lt != &null
            && rt != &null
            && !lt->is_dependent()
            && !rt->is_dependent()
            && !lt->is_instantiation_dependent()
            && !rt->is_instantiation_dependent()
        if lift {
            lifted = self.dyn()->sc->diag->lift_suppress()
        }

        // unify_operands fails both when neither side converts and when
        // both do (`char` and `u32`): the second is an ambiguity, and
        // "neither converts" would send the reader looking for a missing
        // conversion (P387).
        var why = "neither converts implicitly to the other"
        if lt != &null && rt != &null {
            var unsafe *lv = self.dyn()->tu.as_value(lt)
            var unsafe *rv = self.dyn()->tu.as_value(rt)
            if self.dyn()->conv.implicit_builtin(lv, rv) != ImplicitRank::None
                && self.dyn()->conv.implicit_builtin(rv, lv) != ImplicitRank::None {
                why = "each converts implicitly to the other, so the mix is ambiguous"
            }
        }

        self.dyn()->sc->diag->report(
            DiagID::SC033E,
            n->range.start,
            f"operands '{self.dyn()->tu.str(lt)}' and '{self.dyn()->tu.str(rt)}' do not unify; {why}",
        ).first(n->range)->note(
            n->range.start,
            "cast one side explicitly with 'as' to choose the result type",
        )->emit()
        if lift {
            self.dyn()->sc->diag->restore_suppress(lifted)
        }

        n->poison()
    }

    /// `a === b`: both present and equal (Compiler/Spec/Nullables.md#identity), the `==` being
    /// the one the VALUES have. Needs a nullable operand. A nullable pointer
    /// compares what it points to (TypeUtil::identity_derefs), so then both
    /// sides must be pointers and their pointees are compared.
    ///
    /// The `==` is resolved HERE, on the unwrapped types, and recorded on
    /// this node (resolved_op / op_rewrite / tag_eq): CoalesceLowering
    /// builds the `a == b` of the expansion after typing, and OperatorLowering
    /// can only lower a `==` whose operator typing chose. Nothing after
    /// typing can bind a user `op ==`.
    priv fn _type_identity(self,
                           n:  unsafe *BinaryOperatorExpr,
                           lt: unsafe *Type,
                           rt: unsafe *Type) -> unsafe *Type {
        var ln = self.dyn()->tu.nullable_inner(lt)
        var rn = self.dyn()->tu.nullable_inner(rt)
        if ln == &null && rn == &null {
            self.dyn()->sc->diag->report(
                DiagID::SC034E,
                n->range.start,
                f"'===' needs a nullable operand; '{self.dyn()->tu.str(lt)}' and '{self.dyn()->tu.str(rt)}' are not nullable",
            ).first(n->range)->note(
                n->range.start,
                "'===' is 'both present and equal'; on values that cannot be null it is '=='",
            )->emit()
            n->poison()
            return &null
        }

        var li = self.dyn()->tu.strip_nullable(lt)
        var ri = self.dyn()->tu.strip_nullable(rt)
        if self.dyn()->tu.identity_derefs(lt, rt) {
            var lp = self.dyn()->tu.pointee(li)
            var rp = self.dyn()->tu.pointee(ri)
            if lp == &null || rp == &null {
                self._identity_not_pointers(n, lt, rt)
                return &null
            }

            if (self.dyn()->tu.is_unsafe_ptr(li) || self.dyn()->tu.is_unsafe_ptr(ri))
                && !self.dyn()->in_unsafe() {
                self.dyn()->sc->diag->report(
                    DiagID::SC263E,
                    n->range.start,
                    f"'===' on '{self.dyn()->tu.str(lt)}' and '{self.dyn()->tu.str(rt)}' dereferences a raw pointer, which requires an unsafe context",
                ).first(n->range)->note(
                    n->range.start,
                    "write it inside 'unsafe { ... }', or compare the addresses with '=='",
                )->emit()
                n->poison()
                return &null
            }

            li = lp
            ri = rp
        }

        if self._identity_eq(n, canon_unqual(li), canon_unqual(ri)) {
            return self.dyn()->tu.builtin(BuiltinKind::Bool)
        }

        return &null
    }

    /// SC033E for `===` through a nullable pointer whose other side is no
    /// pointer: the pointees are what it compares (Compiler/Spec/Nullables.md#identity).
    priv fn _identity_not_pointers(self,
                                   n:  unsafe *BinaryOperatorExpr,
                                   lt: unsafe *Type,
                                   rt: unsafe *Type) {
        self.dyn()->fail(
            n,
            DiagID::SC033E,
            f"'===' operands '{self.dyn()->tu.str(lt)}' and '{self.dyn()->tu.str(rt)}' do not unify: on a nullable pointer '===' compares what it points to, so the other side must be a pointer too",
        )
    }

    /// `x === null` / `null === x`: an error, since `===` is true only when
    /// both sides hold a value. The fix-it writes the null test it meant,
    /// `!x?`, when `x` is a name or a field path (anything else would need
    /// parentheses the fix-it cannot judge).
    priv fn _identity_null(self, n: unsafe *BinaryOperatorExpr, null_left: bool) -> unsafe *Type {
        var unsafe *other = if (null_left) => (n->rhs) else => n->lhs
        if null_literal_of(other) == &null {
            self.dyn()->type_of(other, &null)
        }

        var b = self.dyn()->sc->diag->report(
            DiagID::SC264E,
            n->range.start,
            "'===' with 'null' is never true: '===' holds only when both sides have a value",
        )

        b.first(n->range)
        var x = self.dyn()->tu.strip_parens(other)
        if x != &null && (isa<NamedIdentExpr>(x) || isa<ChainExpr>(x)) {
            var sp = self.dyn()->sc->ctx->get_spelling(x->range)
            b.fix(n->range, f"!{sp}?", f"test '{sp}' for null")
        } else {
            b.note(n->range.start, "to test for null, write '!x?' (or 'x == null')")
        }

        b.emit()
        n->poison()
        return &null
    }

    /// The `==` of `===`'s expansion, on the unwrapped types \p li / \p ri:
    /// the same answers `a == b` gets on two values (a user `op ==`, one
    /// derived from `op <=>`, an ADT's tag compare, builtin equality),
    /// recorded on \p n. False after reporting an error.
    priv fn _identity_eq(self, n: *BinaryOperatorExpr, li: unsafe *Type, ri: unsafe *Type) -> bool {
        var lb = self.dyn()->tu.kind_of(li) != BuiltinKind::COUNT
        var rb = self.dyn()->tu.kind_of(ri) != BuiltinKind::COUNT
        if lb && rb {
            if self.unify_operands(li, ri) != &null {
                return true
            }

            self.dyn()->fail(
                n,
                DiagID::SC033E,
                f"'===' operands '{self.dyn()->tu.str(n->lhs->type_)}' and '{self.dyn()->tu.str(n->rhs->type_)}' do not unify",
            )

            return false
        }

        var found = false
        var unsafe *ut = self._identity_op(
            n,
            TokenKind::OpEqualEqual,
            li,
            ri,
            "op ==",
            unsafe &found,
        )

        if found {
            if ut == &null {
                return false
            }

            if !self.dyn()->tu.is_bool(ut) {
                self.dyn()->fail(
                    n,
                    DiagID::SC066E,
                    f"'===' needs 'op ==' on '{self.dyn()->tu.str(li)}' to return 'bool', not '{self.dyn()->tu.str(ut)}'",
                )

                return false
            }

            return true
        }

        // Derived from `op <=>`, Kairo's rule (see type_binary).
        if !self._is_imported_record(li) && !self._is_imported_record(ri) {
            ut = self._identity_op(
                n,
                TokenKind::OpLessEqualGreater,
                li,
                ri,
                "op <=>",
                unsafe &found,
            )

            if found {
                if ut == &null {
                    return false
                }

                n->op_rewrite = OpRewrite::Cmp
                return true
            }
        }

        if self._is_plain_record(li) || self._is_plain_record(ri) {
            var unsafe *rec = if (self._is_plain_record(li)) => (li) else => ri
            self.dyn()->fail(
                n,
                DiagID::SC066E,
                f"'===' compares the values with their 'op ==', and '{self.dyn()->tu.str(rec)}' has none",
            )

            return false
        }

        if li == ri && self._adt_of(li) != &null {
            n->tag_eq = true
            return true
        }

        // A bounds-checked parameter's `==` is only ever its bounds' (D0),
        // and they were asked above: `T === T` unifying is no comparison.
        var        gq  = self.dyn()->tu.op_checked_head(li)
        var unsafe *gt = li
        if gq == &null {
            gq = self.dyn()->tu.op_checked_head(ri)
            gt = ri
        }

        if gq != &null {
            var pname = self.dyn()->tu.head_spelling(gt)
            self.dyn()->needs_bound(
                n,
                gq,
                self._bounded(gt),
                f"'===' on '{self.dyn()->tu.str(n->lhs->type_)}' compares the values with 'op ==', so it needs a bound on '{pname}' that declares 'op =='",
            )

            return false
        }

        if self.unify_operands(li, ri) != &null {
            return true
        }

        self.dyn()->fail(
            n,
            DiagID::SC066E,
            f"'===' cannot compare '{self.dyn()->tu.str(li)}' with '{self.dyn()->tu.str(ri)}': there is no '==' for them",
        )

        return false
    }

    /// resolve_user_op for `===`'s `==`, against the UNWRAPPED operand types
    /// \p li / \p ri rather than the operands' own `T?`: the expansion
    /// compares the narrowed values. No argument is converted here (the
    /// operands are nullable; the values exist only in the expansion), so
    /// finish_call_args, whose check_convertible would read each `T?` as a
    /// value and report it may be null, is not run.
    priv fn _identity_op(self,
                         n:           *BinaryOperatorExpr,
                         k:           TokenKind,
                         li:          unsafe *Type,
                         ri:          unsafe *Type,
                         const label: string,
                         found:       unsafe *bool) -> unsafe *Type {
        *found = false
        var cands = cxx::std::vector<unsafe *Decl>()
        var frees = cxx::std::vector<unsafe *Decl>()
        self._gather(
            DeclName::op_name(k, TokenKind::TkUnknown),
            li,
            ri,
            -1,
            unsafe &cands,
            unsafe &frees,
        )

        if cands.size() == 0 && frees.size() == 0 {
            return &null
        }

        *found = true
        var margs = cxx::std::vector<ArgInfo>()
        var ra    = self._typed_arg(n->rhs, ri)
        ra.cat = Expr::ValueCategory::LValue // the narrowed read is the place's value.
        margs.push_back(ra)
        var fargs = cxx::std::vector<ArgInfo>()
        var la    = self._typed_arg(n->lhs, li)
        la.cat = Expr::ValueCategory::LValue
        fargs.push_back(la)
        fargs.push_back(ra)
        var r = self.dyn()->ovl.resolve_mixed(
            &cands,
            &margs,
            true,
            &frees,
            &fargs,
            n->range,
            label,
            li,
        )

        if r.outcome == OvlOutcome::Dependent {
            self.dyn()->mark_unknown(n)
            return &null
        }

        if r.outcome != OvlOutcome::Selected {
            self.dyn()->poison_only(n)
            return &null
        }

        var rt = self.dyn()->call_result_type(r.decl, &r)
        self._record(n, r.decl, r.via_free, r.instance)
        return rt
    }

    /// `x in xs`: containment. The RIGHT operand is the receiver -- xs's
    /// `op in (self, x)`, or a free `op in (xs, x)`. The iteration form
    /// `op in (self)` shares the name and drops out on arity.
    priv fn _type_contains(self,
                           n:  unsafe *BinaryOperatorExpr,
                           lt: unsafe *Type,
                           rt: unsafe *Type) -> unsafe *Type {
        var found = false
        var args  = cxx::std::vector<unsafe *Expr>()
        args.push_back(n->lhs)
        var unsafe *ut = self.resolve_user_op(
            n,
            TokenKind::KwIn,
            TokenKind::TkUnknown,
            n->rhs,
            rt,
            lt,
            args,
            -1,
            "op in",
            unsafe &found,
        )

        if found {
            return ut
        }

        self.dyn()->fail(
            n,
            DiagID::SC066E,
            f"'in' needs an 'op in' on '{self.dyn()->tu.str(rt)}' taking a '{self.dyn()->tu.str(lt)}'",
        )

        return &null
    }

    /// `b ^^ e`. A record base goes through its `op ^^`; a primitive base is
    /// a call to the `pow` lang item, whose `B` deduces from the base and `E`
    /// from the exponent, so the result IS the base's type.
    priv fn _type_pow(self, n: unsafe *BinaryOperatorExpr, expected: unsafe *Type) -> unsafe *Type {
        var lt = self.dyn()->type_of(n->lhs, expected)
        var rt = self.dyn()->type_of(n->rhs, &null)
        var tl = self.dyn()->reject_type_value(n->lhs)
        var tr = self.dyn()->reject_type_value(n->rhs)
        if tl || tr {
            self.dyn()->poison_only(n)
            return &null
        }

        if self.dyn()->propagate(n, n->lhs) || self.dyn()->propagate(n, n->rhs) {
            return &null
        }

        if lt == &null || rt == &null {
            return &null
        }

        lt = self.dyn()->tu.as_value(lt)
        rt = self.dyn()->tu.as_value(rt)
        // A bounds-checked base has the `op ^^` its bounds grant, or none.
        var pg = self.dyn()->tu.op_checked_head(lt)
        if pg != &null && self._bounded(lt) {
            var pfound = false
            var pargs  = cxx::std::vector<unsafe *Expr>()
            pargs.push_back(n->rhs)
            var put = self.resolve_user_op(
                n,
                TokenKind::OpCaretCaret,
                TokenKind::TkUnknown,
                n->lhs,
                lt,
                rt,
                pargs,
                -1,
                "op ^^",
                &pfound,
            )

            if pfound {
                return put
            }
        }

        if pg != &null {
            self.dyn()->needs_bound(
                n,
                pg,
                self._bounded(lt),
                f"'^^' on '{self.dyn()->tu.head_spelling(lt)}' needs a bound that declares 'op ^^'",
            )

            return &null
        }

        if self._is_dependent(lt) || self._is_dependent(rt) {
            self.dyn()->mark_unknown(n)
            return &null
        }

        if self.dyn()->tu.kind_of(lt) == BuiltinKind::COUNT {
            var found = false
            var args  = cxx::std::vector<unsafe *Expr>()
            args.push_back(n->rhs)
            var ut = self.resolve_user_op(
                n,
                TokenKind::OpCaretCaret,
                TokenKind::TkUnknown,
                n->lhs,
                lt,
                rt,
                args,
                -1,
                "op ^^",
                &found,
            )

            if found {
                return ut
            }

            self.dyn()->fail(n, DiagID::SC066E, f"no 'op ^^' on '{self.dyn()->tu.str(lt)}'")
            return &null
        }

        if !self.dyn()->tu.is_numeric(lt) {
            self.dyn()->fail(
                n,
                DiagID::SC067E,
                f"'^^' needs a numeric base, not '{self.dyn()->tu.str(lt)}'",
            )

            return &null
        }

        if !self.dyn()->tu.is_integer(rt) {
            if self.dyn()->tu.is_float(rt) {
                self.dyn()->fail(
                    n,
                    DiagID::SC067E,
                    f"the exponent of '^^' must be an integer, not '{self.dyn()->tu.str(rt)}'; a real exponent is a library function",
                )
            } else {
                self.dyn()->fail(
                    n,
                    DiagID::SC067E,
                    f"the exponent of '^^' must be an integer, not '{self.dyn()->tu.str(rt)}'",
                )
            }

            return &null
        }

        var d = self.dyn()->sc->well_known->get(WellKnownType::Pow)
        if d == &null {
            self.dyn()->missing_lang_item(n, to_string(WellKnownType::Pow))
            return &null
        }

        var cands = cxx::std::vector<*Decl>()
        cands.push_back(d)
        var fargs = cxx::std::vector<ArgInfo>()
        fargs.push_back(self._typed_arg(n->lhs, lt))
        fargs.push_back(self._typed_arg(n->rhs, rt))
        var r = self.dyn()->ovl.resolve(&cands, &fargs, false, n->range, "op ^^")
        if r.outcome == OvlOutcome::Dependent {
            self.dyn()->mark_unknown(n)
            return &null
        }

        if r.outcome != OvlOutcome::Selected {
            self.dyn()->poison_only(n)
            return &null
        }

        self.dyn()->finish_call_args(r.decl, &fargs, &r)
        self.dyn()->call_result_type(r.decl, &r) // registers the instance; B := lt.
        self._record(n, r.decl, true, r.instance)
        return canon_unqual(lt)
    }

    /// # unary

    /// `unwrap!(x)`: `x`'s value, `T` for an `x: T?` (Compiler/Spec/Nullables.md#unwrap). It
    /// is not a read of `x` as `T` (§4), so `x` needs no check; it IS one
    /// afterwards, since on null the program has ended: `x` is non-null
    /// after it. An lvalue when `x` is a place, so `unwrap!(x).v = 1`
    /// writes `x`'s payload. Not a panic site. A dependent `T?` answers
    /// `T` now; any other dependent operand defers.
    fn type_unwrap(self, n: unsafe *UnwrapExpr, expected: unsafe *Type) -> unsafe *Type {
        if n->operand == &null {
            self.dyn()->poison_only(n)
            return &null
        }

        var want: unsafe *Type = if (expected != &null
                                     && self.dyn()->tu.nullable_inner(expected) == &null
                                     && !self.dyn()->tu.is_builtin(
                                         expected,
                                         BuiltinKind::Void,
                                     )) => (self.dyn()->sc->types->nullable(canon_unqual(expected)))
                                 else => &null
        var ot = self.dyn()->type_of(n->operand, want)
        if self.dyn()->propagate(n, n->operand) {
            return &null
        }

        if ot == &null {
            self.dyn()->mark_unknown(n)
            return &null
        }

        var inner = self.dyn()->flow.narrowed_type(ot)
        if inner == &null {
            if self._is_dependent(ot) && self.dyn()->tu.checked_head(ot) == &null {
                self.dyn()->mark_unknown(n)
                return &null
            }

            self._not_nullable_unwrap(n, self.dyn()->tu.as_value(ot))
            return &null
        }

        var place = null_place_of(n->operand)
        if place.size() > 0 && n->operand->value_category == Expr::ValueCategory::LValue {
            n->value_category = Expr::ValueCategory::LValue
        } else {
            n->value_category = Expr::ValueCategory::RValue
        }

        self.dyn()->flow.unwrapped(n->operand, n->range)
        return inner
    }

    /// `unwrap!(x)` on an `x` that is never null: SC001E, with the fix-it
    /// that leaves `x` alone.
    priv fn _not_nullable_unwrap(self, n: *UnwrapExpr, ot: *Type) {
        var x = self.dyn()->tu.strip_parens(n->operand)
        var id = if (x != &null && isa<NamedIdentExpr>(x)) => (cast<NamedIdentExpr>(x))
                 else => &null
        var text = self.dyn()->sc->ctx->get_spelling(n->operand->range)
        var b = self.dyn()->sc->diag->report(
            DiagID::SC260E,
            n->range.start,
            f"'{text}' is not nullable ('{self.dyn()->tu.str(ot)}'); 'unwrap!' takes a nullable, and this value is never null",
        )

        b.first(n->range)
        if id != &null && id->resolved_decl != &null {
            b.note(
                id->resolved_decl->range.start,
                f"'{text}' is declared '{self.dyn()->tu.str(ot)}' here",
            )
        }

        b.remove(SourceRange(n->range.start, n->operand->range.start), "use the value as it is")
        b.remove(SourceRange(n->operand->range.end, n->range.end), "use the value as it is")
        b.emit()
        n->poison()
    }

    fn type_unary(self, n: unsafe *UnaryOperatorExpr, expected: unsafe *Type) -> unsafe *Type {
        var k = n->op_token.kind

        // `-literal` folds the sign into the fit check.
        if n->is_prefix() && k == TokenKind::OpMinus {
            var inner = self.dyn()->tu.strip_parens(n->operand)
            if inner != &null && isa<IntegerLiteralExpr>(inner) {
                var t = self.dyn()->type_int_literal(
                    cast<IntegerLiteralExpr>(inner),
                    expected,
                    true,
                )

                self.dyn()->finish(inner, t)
                if t == &null {
                    self.dyn()->poison_only(n)
                    return &null
                }

                if !self.dyn()->tu.is_signed_int(t) && !self.dyn()->tu.is_float(t) {
                    self.dyn()->fail(
                        n,
                        DiagID::SC068E,
                        f"cannot negate a literal of unsigned type '{self.dyn()->tu.str(t)}'",
                    )

                    return &null
                }

                return t
            }
        }

        var ot = self.dyn()->type_of(
            n->operand,
            self.cast_operand_expected(
                n->operand,
                if (k == TokenKind::OpMinus
                    || k == TokenKind::OpPlus
                    || k == TokenKind::OpTilde) => (expected)
                else => &null,
            ),
        )

        if ot == &null && self.dyn()->reject_type_value(n->operand) {
            self.dyn()->poison_only(n)
            return &null
        }

        if self.dyn()->propagate(n, n->operand) {
            return &null
        }

        if ot == &null {
            return &null
        }

        // `v.at(i)` is `i32&`; every arm below classifies the value it names,
        // and `&`/`*` want the referee too -- `&v.at(i)` is `*i32`, as in C++.
        // `&` keeps the lvalue's cv, though: as_value drops it, and taking the
        // address of a `const i32` must give `*const i32`, not a `*i32` that
        // launders the qualifier away.
        var place = ot
        if isa<CXXLValueRefType>(place) {
            place = cast<CXXLValueRefType>(place)->referee
        } else if isa<CXXRValueRefType>(place) {
            place = cast<CXXRValueRefType>(place)->referee
        }

        ot = self.dyn()->tu.as_value(ot)

        // `x?` on a nullable is the null test (Compiler/Spec/Nullables.md#null-test), whatever
        // its inner: before the user-operator lookup, so a payload record's
        // own `op ?` never answers for its nullable, and before the
        // dependent deferral, so `t?` on a `T?` is `bool` in a generic body
        // too. Only the OUTER level is tested: `x?` on `(i32?)?` asks the
        // outer nullable. NullTestLowering lowers it (null_test_of).
        if k == TokenKind::OpQuestion
            && n->is_postfix()
            && self.dyn()->tu.nullable_inner(ot) != &null {
            return self.dyn()->tu.builtin(BuiltinKind::Bool)
        }

        // Every other operator but `&` reads its operand's value (Compiler/Spec/Nullables.md
        // §4): `-a`, `*p`, `!b`, `++i` on a nullable place proven non-null
        // here act on the value; on one that is not, the nullness error.
        if k != TokenKind::OpAmp
            && k != TokenKind::OpQuestion
            && k != TokenKind::OpEllipsis
            && self.dyn()->tu.nullable_inner(ot) != &null {
            var nt = self.dyn()->read_value(n->operand)
            if nt == &null {
                self.dyn()->poison_only(n)
                return &null
            }

            place = nt
            if isa<CXXLValueRefType>(place) {
                place = cast<CXXLValueRefType>(place)->referee
            } else if isa<CXXRValueRefType>(place) {
                place = cast<CXXRValueRefType>(place)->referee
            }

            ot = self.dyn()->tu.as_value(nt)
        }

        // user operator first for non-primitives. `++`/`--` keep only the
        // declared fixity that matches the use.
        if self.dyn()->tu.kind_of(ot) == BuiltinKind::COUNT
            && (!self._is_dependent(ot) || self._bounded(ot))
            && k != TokenKind::OpAmp
            && k != TokenKind::OpStar {
            var fix: i32 = -1
            if k == TokenKind::OpPlusPlus || k == TokenKind::OpMinusMinus {
                fix = if (n->is_postfix()) => (1) else => 0
            }

            var found = false
            var args  = cxx::std::vector<*Expr>()
            var ut = self.resolve_user_op(
                n,
                k,
                TokenKind::TkUnknown,
                n->operand,
                ot,
                &null,
                args,
                fix,
                self._label(n->op_token),
                &found,
            )

            if found {
                return ut
            }
        }

        // Unary `*` is the pointer dereference and not overloadable in Kairo,
        // but a C++ class's `operator*` is how every C++ iterator and smart
        // pointer is read, so on an imported record it is looked up like any
        // other operator. Only there: a Kairo record's `op *` is the binary
        // one, and offering it to `*x` would turn "not a pointer" into a
        // misleading overload failure.
        if k == TokenKind::OpStar
            && self.dyn()->tu.pointee(ot) == &null
            && self._is_imported_record(ot) {
            var found = false
            var args  = cxx::std::vector<*Expr>()
            var ut = self.resolve_user_op(
                n,
                k,
                TokenKind::TkUnknown,
                n->operand,
                ot,
                &null,
                args,
                -1,
                "operator*",
                &found,
            )

            if found {
                return ut
            }
        }

        // Same rule as the binary case: a dependent operand defers. `&x` is
        // the exception -- its result is `*T` whatever T turns out to be, so
        // there is nothing to wait for.
        // A bounds-checked parameter defers nothing (D0): `t?` and `*t` get
        // the switch's own errors (a T is no nullable and no pointer), and
        // every other operator is the bounds' to grant, which they did not.
        var ug = self.dyn()->tu.op_checked_head(ot)
        if ug != &null
            && k != TokenKind::OpAmp
            && k != TokenKind::OpStar
            && k != TokenKind::OpQuestion
            && k != TokenKind::OpEllipsis {
            var sym = self.dyn()->sc->ctx->get_spelling(n->op_token)
            if k == TokenKind::OpExclaim || k == TokenKind::KwNot {
                return self._unary_bool(n, ot)
            }

            var pname = self.dyn()->tu.head_spelling(ot)
            self.dyn()->needs_bound(
                n,
                ug,
                self._bounded(ot),
                f"'{sym}' on '{pname}' needs a bound that declares 'op {sym}'",
            )

            return &null
        }

        // `*p` with p a pointer to a dependent T is a T whatever T turns out to
        // be, as `&x` is a `*T`: deferring it left `var m = *p` in a generic
        // body with no type, and codegen reported it (I011W). A dependent
        // operand that is not yet known to be a pointer still defers.
        var deref_known = k == TokenKind::OpStar && self.dyn()->tu.pointee(ot) != &null
        if k != TokenKind::OpAmp && (!deref_known) && self._is_dependent(ot) && ug == &null {
            self.dyn()->mark_unknown(n)
            return &null
        }

        match k {
            case TokenKind::OpExclaim {
                return self._unary_bool(n, ot)
            } case TokenKind::KwNot {
                return self._unary_bool(n, ot)
            } case TokenKind::OpMinus {
                if self.dyn()->tu.is_float(ot) || self.dyn()->tu.is_signed_int(ot) {
                    return canon_unqual(ot)
                }

                self.dyn()->fail(
                    n,
                    DiagID::SC067E,
                    f"cannot negate a value of type '{self.dyn()->tu.str(ot)}'",
                )

                return &null
            } case TokenKind::OpPlus {
                if self.dyn()->tu.is_numeric(ot) {
                    return canon_unqual(ot)
                }

                self.dyn()->fail(
                    n,
                    DiagID::SC067E,
                    f"unary '+' requires a numeric operand, not '{self.dyn()->tu.str(ot)}'",
                )

                return &null
            } case TokenKind::OpTilde {
                return self._unary_bits(n, ot)
            } case TokenKind::KwCompl {
                return self._unary_bits(n, ot)
            } case TokenKind::OpAmp {
                if !self.dyn()->is_lvalue(n->operand) {
                    self.dyn()->fail(n, DiagID::SC069E, "cannot take the address of a temporary")
                    return &null
                }

                // The pointer may write the place behind the analysis's back
                // until a consumer accounts for it (Compiler/Spec/Nullables.md#weakening, 3.7).
                self.dyn()->flow.address_taken(n, place)
                return self.dyn()->sc->types->pointer(place, false)
            } case TokenKind::OpStar {
                self.dyn()->flow.consumed(n->operand) // `*p` reads or writes where p points; no escape.
                var p = self.dyn()->tu.pointee(ot)
                if p == &null {
                    if self.dyn()->tu.nullable_inner(ot) != &null {
                        self.dyn()->fail(
                            n,
                            DiagID::SC070E,
                            f"cannot dereference nullable '{self.dyn()->tu.str(ot)}'; check for null or use '?.'",
                        )
                    } else {
                        self.dyn()->fail(
                            n,
                            DiagID::SC070E,
                            f"cannot dereference non-pointer type '{self.dyn()->tu.str(ot)}'",
                        )
                    }

                    return &null
                }

                if self.dyn()->tu.is_void(p) {
                    self.dyn()->fail(n, DiagID::SC070E, "cannot dereference '*void'")
                    return &null
                }

                n->value_category = Expr::ValueCategory::LValue
                // `*x` through a closure's pointer capture is the captured
                // variable's place (Compiler/Spec/Nullables.md#aliases-and-closures): a use of it, as a name is.
                if null_flow_type_is_nullable(p) {
                    var dp = null_place_of(unsafe (n as unsafe *Expr))
                    if dp.size() > 0 {
                        self.dyn()->flow.note_read(n, &dp)
                    }
                }

                return p
            } case TokenKind::OpPlusPlus {
                return self._incdec(n, ot)
            } case TokenKind::OpMinusMinus {
                return self._incdec(n, ot)
            } case TokenKind::OpEllipsis {
                // postfix `x...`: a pack expansion in expression position.
                self.dyn()->mark_unknown(n)
                return &null
            } case TokenKind::OpQuestion {
                if n->is_postfix() {
                    self._not_nullable_test(n, ot)
                    return &null
                }

                self.dyn()->fail(
                    n,
                    DiagID::SC066E,
                    f"unary operator '?' is not defined on '{self.dyn()->tu.str(ot)}'",
                )

                return &null
            } default {
                self.dyn()->fail(
                    n,
                    DiagID::SC066E,
                    f"unary operator '{self.dyn()->sc->ctx->get_spelling(n->op_token)}' is not defined on '{self.dyn()->tu.str(ot)}'",
                )

                return &null
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
    priv fn _type_null_compare(self,
                               n:     unsafe *BinaryOperatorExpr,
                               lit:   unsafe *NullLiteralExpr,
                               other: unsafe *Expr,
                               done:  unsafe *bool) -> unsafe *Type {
        *done = true
        var ot = self.dyn()->type_of(other, &null)
        if self.dyn()->propagate(n, other) {
            return &null
        }

        if ot == &null {
            return &null
        }

        var ov = self.dyn()->tu.as_value(ot)
        if self.dyn()->tu.nullable_inner(ov) != &null {
            var lt = self.dyn()->type_of(lit, canon_unqual(ov))
            if self.dyn()->propagate(n, lit) || lt == &null {
                return &null
            }

            return self.dyn()->tu.builtin(BuiltinKind::Bool)
        }

        // A bounds-checked parameter is never null whatever it is
        // instantiated with (D0: the body sees a T, and only a `T?` can be
        // null), so it gets the non-nullable error below.
        if self._is_dependent(ov) && self.dyn()->tu.checked_head(ov) == &null {
            self.dyn()->mark_unknown(n)
            return &null
        }

        if lit->is_ref {
            *done = false
            return &null
        }

        var x = self.dyn()->tu.strip_parens(other)
        var id = if (x != &null && isa<NamedIdentExpr>(x)) => (cast<NamedIdentExpr>(x))
                 else => &null
        var what = if (id == &null) => ("the operand")
                   else => f"'{self.dyn()->sc->ctx->get_spelling(id->name)}'"
        // A raw pointer CAN be null, but its null is the pointer `&null`
        // (nullables.md, Pointers and nullability), and that comparison is
        // a real one: same mistake, different wording and an exact fix.
        if self.dyn()->tu.is_unsafe_ptr(ov) {
            var r = self.dyn()->sc->diag->report(
                DiagID::SC261E,
                n->range.start,
                f"{what} is a raw pointer, not a nullable; a raw pointer's null is '&null'",
            )

            r.first(other->range)
            r.second(lit->range)
            r.fix(lit->range, "&null", "compare the pointer with '&null'")
            r.emit()
            n->poison()
            return &null
        }

        var b = self.dyn()->sc->diag->report(
            DiagID::SC260E,
            n->range.start,
            f"{what} is not nullable; '{self.dyn()->tu.str(ov)}' is never null, so comparing it with 'null' is meaningless",
        )

        b.first(other->range)
        b.second(lit->range)
        if id != &null && id->resolved_decl != &null {
            b.note(
                id->resolved_decl->range.start,
                f"declared '{self.dyn()->tu.str(ov)}' here; a type that may be null is written 'T?'",
            )
        }

        b.emit()
        n->poison()
        return &null
    }

    /// `x?` on a value that cannot be null. SC066E (no operator for this
    /// operand type): `?` is the null test and has nothing to test on a
    /// `T`; a record's own `op ?` was already tried. No fix-it: dropping
    /// the `?` leaves a non-bool where a condition wanted one, and which
    /// test was meant is not knowable. The note points at the declaration
    /// that made it non-nullable, when the operand names one.
    priv fn _not_nullable_test(self, n: *UnaryOperatorExpr, ot: *Type) {
        if n->is_poisoned() {
            return
        }

        var x = self.dyn()->tu.strip_parens(n->operand)
        var id = if (x != &null && isa<NamedIdentExpr>(x)) => (cast<NamedIdentExpr>(x))
                 else => &null
        var what = if (id == &null) => ("the operand")
                   else => f"'{self.dyn()->sc->ctx->get_spelling(id->name)}'"
        var b = self.dyn()->sc->diag->report(
            DiagID::SC066E,
            n->range.start,
            f"{what} is not nullable; '?' tests a nullable, and '{self.dyn()->tu.str(ot)}' is never null",
        )

        b.first(n->range)
        if id != &null && id->resolved_decl != &null {
            b.note(
                id->resolved_decl->range.start,
                f"declared '{self.dyn()->tu.str(ot)}' here; a type that may be null is written 'T?'",
            )
        }

        b.emit()
        n->poison()
    }

    priv fn _unary_bool(self, n: *UnaryOperatorExpr, ot: unsafe *Type) -> unsafe *Type {
        if self.dyn()->tu.is_bool(ot) {
            return canon_unqual(ot)
        }

        self.dyn()->fail(
            n,
            DiagID::SC067E,
            f"'!' requires a 'bool' operand, not '{self.dyn()->tu.str(ot)}'",
        )

        return &null
    }

    priv fn _unary_bits(self, n: *UnaryOperatorExpr, ot: unsafe *Type) -> unsafe *Type {
        if self.dyn()->tu.is_integer(ot) || self.dyn()->tu.is_builtin(ot, BuiltinKind::Byte) {
            return canon_unqual(ot)
        }

        self.dyn()->fail(
            n,
            DiagID::SC067E,
            f"'~' requires an integer or byte operand, not '{self.dyn()->tu.str(ot)}'",
        )

        return &null
    }

    priv fn _incdec(self, n: *UnaryOperatorExpr, ot: unsafe *Type) -> unsafe *Type {
        // `++p` / `--p` on a pointer of either kind is `p += 1` / `p -= 1`,
        // and takes that rule as it is: a void pointee has no unit
        // to move by. A safe pointer is allowed: staying in its allocation
        // is Tether's to prove, as for `p + 1`. C++'s own `++` on the
        // pointer: no pointer type has a wrap form.
        var pp = self.dyn()->tu.pointee(ot)
        if pp != &null {
            if self.dyn()->tu.is_void(pp) {
                self.dyn()->fail(
                    n,
                    DiagID::SC067E,
                    f"pointer arithmetic moves in units of the pointee, and '{self.dyn()->tu.str(ot)}' points to void; cast it to a typed pointer first",
                )

                return &null
            }

            if !self.dyn()->is_lvalue(n->operand) {
                self.dyn()->fail(n, DiagID::SC071E, "'++'/'--' require an assignable operand")
                return &null
            }

            if self._reject_const_write(unsafe (n as unsafe *Expr), n->operand, "increment or decrement") {
                return &null
            }

            if n->is_prefix() {
                n->value_category = Expr::ValueCategory::LValue
            }

            return ot
        }

        if !self.dyn()->tu.is_integer(ot) {
            var what = if (n->op_token.kind == TokenKind::OpPlusPlus) => ("'++'") else => "'--'"
            if self.dyn()->tu.kind_of(ot) == BuiltinKind::COUNT {
                var fixname = if (n->is_postfix()) => ("r") else => "l"
                self.dyn()->fail(
                    n,
                    DiagID::SC066E,
                    f"no 'op {fixname}{self.dyn()->sc->ctx->get_spelling(n->op_token)}' on '{self.dyn()->tu.str(ot)}'",
                )

                return &null
            }

            self.dyn()->fail(
                n,
                DiagID::SC067E,
                f"{what} requires an integer operand, not '{self.dyn()->tu.str(ot)}'",
            )

            return &null
        }

        if !self.dyn()->is_lvalue(n->operand) {
            self.dyn()->fail(n, DiagID::SC071E, "'++'/'--' require an assignable operand")
            return &null
        }

        if self._reject_const_write(unsafe (n as unsafe *Expr), n->operand, "increment or decrement") {
            return &null
        }

        if n->is_prefix() {
            n->value_category = Expr::ValueCategory::LValue
        }

        return ot
    }

    /// # assignment

    /// `self.f = e` directly in a constructor of f's record: for an array
    /// field this may be its initialization, which is no assignment, so the
    /// array rule (SC071E) is CtorInitCheck's to apply once it knows which
    /// write comes first. A closure in the constructor has a frame of its
    /// own, with no function, so its writes stay assignments.
    priv fn _ctor_field_write(self, n: unsafe *AssignOperatorExpr) -> bool {
        var fr = self.dyn()->cur_frame()
        if fr == &null || fr->fn_decl == &null {
            return false
        }

        var fd = fr->fn_decl
        if fd->is_operator || !fd->is_method() || fd->adt_role != AdtRole::None {
            return false
        }

        var dc = fd->semantic_dc
        if dc == &null || !dc->is_type_scope() || dc->dc_owner == &null {
            return false
        }

        if self.dyn()->tu.decl_name(fd) != self.dyn()->tu.decl_name(dc->dc_owner) {
            return false
        }

        var unsafe *c = dyn_cast<ChainExpr>(n->lhs)
        if c == &null || c->steps.size() != 1 {
            return false
        }

        var unsafe *ni = dyn_cast<NamedIdentExpr>(c->base)
        if ni == &null || ni->resolved_decl == &null {
            return false
        }

        var unsafe *p = dyn_cast<ParamDecl>(ni->resolved_decl)
        if p == &null || !p->is_self {
            return false
        }

        var unsafe *st = c->steps.get(0)
        if st->resolved_decl == &null || !isa<FieldDecl>(st->resolved_decl) {
            return false
        }

        var unsafe *f = cast<FieldDecl>(st->resolved_decl)
        return !f->is_static() && f->semantic_dc == fd->semantic_dc
    }

    /// The variable, parameter or field an assignment writes: `x = v`, or
    /// the last step of `a.b.c = v`. Null for any other place (`*p = v`,
    /// `v[i] = x`), which has no declaration to point a fix-it at.
    priv fn _assigned_decl(self, lhs: unsafe *Expr) -> unsafe *Decl {
        var x = self.dyn()->tu.strip_parens(lhs)
        if x == &null {
            return &null
        }

        var id = dyn_cast<NamedIdentExpr>(x)
        if id != &null {
            return id->resolved_decl
        }

        var ch = dyn_cast<ChainExpr>(x)
        if ch != &null && ch->steps.size() > 0 {
            return ch->steps.get(ch->steps.size() - 1)->resolved_decl
        }

        return &null
    }

    /// The const binding whose element \p x is: `cb` for `cb[i]` or
    /// `cb[i][j]` when every container on the way is const, so a write
    /// through it names the container rather than "a const place" (P921).
    /// Null when \p x is no subscript, or the const came from elsewhere (an
    /// `op []` returning `*const T` on a mutable container).
    priv fn _const_container_decl(self, x: unsafe *Expr) -> unsafe *Decl {
        var unsafe *cur = x
        while true {
            var unsafe *s = dyn_cast<SubscriptExpr>(cur)
            if s == &null {
                break
            }

            var unsafe *b = self.dyn()->tu.strip_parens(s->base)
            if b == &null || b->type_ == &null || (self._object_quals(b->type_) & QUAL_CONST) == 0 {
                return &null
            }

            cur = b
        }

        if cur == x {
            return &null
        }

        var unsafe *d  = self._assigned_decl(cur)
        var unsafe *vd = if (d != &null) => (dyn_cast<VariableDecl>(d)) else => &null
        var unsafe *pd = if (d != &null) => (dyn_cast<ParamDecl>(d)) else => &null
        if (vd != &null && vd->is_const()) || (pd != &null && pd->is_const) {
            return d
        }

        return &null
    }

    /// SC071E for a write through a const lvalue (variables.mdx, "The
    /// `const` Binding Rule"; pointers.mdx, "Const Pointers"): a `const` or
    /// `eval` binding, a `const` parameter, or a place whose type is const
    /// (`*p` through a `*const T`, a `for *x` binder over a const range, a
    /// `const T&` result). \p n is the write (`=`, `op=`, `++`, `--`), \p
    /// lhs what it writes. Without this the write reached clang as CL001E,
    /// or compiled silently where the binding's top-level const is not
    /// emitted (a `const c: *i32` parameter; P347, P839).
    /// A const FIELD is CtorInitCheck's (SC171E): a constructor of its own
    /// record initializes it once, a write this rule cannot tell from an
    /// assignment.
    /// \return whether it reported (the caller stops typing \p n).
    priv fn _reject_const_write(self, n: unsafe *Expr, lhs: unsafe *Expr, verb: string) -> bool {
        var x = self.dyn()->tu.strip_parens(lhs)
        if x == &null {
            return false
        }

        var unsafe *d = self._assigned_decl(x)
        if d != &null && isa<FieldDecl>(d) {
            return false
        }

        var vd: unsafe *VariableDecl = &null
        var pd: unsafe *ParamDecl    = &null
        if d != &null {
            vd = dyn_cast<VariableDecl>(d)
            pd = dyn_cast<ParamDecl>(d)
        }

        var by_decl = (vd != &null && vd->is_const()) || (pd != &null && pd->is_const)
        var by_type = false
        if (!by_decl) && x->type_ != &null {
            var unsafe *t = x->type_
            if isa<CXXLValueRefType>(t) {
                t = cast<CXXLValueRefType>(t)->referee
            }

            by_type = canon_has_const(t)
        }

        if (!by_decl) && (!by_type) {
            return false
        }

        // A deref's operand names the pointer whose `*const` made the place
        // const: the note points at that pointer's declaration.
        if !by_decl {
            vd = &null
            pd = &null
            var unsafe *u = dyn_cast<UnaryOperatorExpr>(x)
            if u != &null && u->is_prefix() && u->op_token.kind == TokenKind::OpStar {
                var unsafe *pdecl = self._assigned_decl(u->operand)
                if pdecl != &null {
                    vd = dyn_cast<VariableDecl>(pdecl)
                    pd = dyn_cast<ParamDecl>(pdecl)
                }
            }
        }

        // An element of a const container (`cb[0] = 5`, `cb` const) is
        // the container's fault, and its declaration is the note.
        var by_owner = false
        if (!by_decl) && vd == &null && pd == &null {
            var unsafe *od = self._const_container_decl(x)
            if od != &null {
                vd       = dyn_cast<VariableDecl>(od)
                pd       = dyn_cast<ParamDecl>(od)
                by_owner = true
            }
        }

        var at = SourceRange::invalid()
        var nm = ""
        if vd != &null {
            nm = self.dyn()->sc->ctx->get_spelling(vd->name)
            at = vd->name.range
        } else if pd != &null {
            nm = self.dyn()->sc->ctx->get_spelling(pd->name)
            at = pd->name.range
        }

        var msg = "cannot " + verb + " a const place"
        if by_decl {
            msg = "cannot " + verb + " \x27" + nm + "\x27: it is const"
        } else if by_owner {
            msg = "cannot " + verb + " an element of \x27" + nm + "\x27: \x27" + nm + "\x27 is const"
        } else if !nm.empty() {
            msg = "cannot " + verb + " \x27*" + nm + "\x27: \x27" + nm + "\x27 points to const"
        }

        if !n->is_poisoned() {
            var b = self.dyn()->sc->diag->report(DiagID::SC071E, n->range.start, msg)
            b.first(lhs->range)
            if at.is_valid() {
                var why = "declared const here"
                if (!by_decl) && (!by_owner) {
                    why = "declared as a pointer to const here"
                }

                b.note(at.start, "\x27" + nm + "\x27 " + why)->first(at)
            }

            // A const element of a mutable container: its `op []` hands out
            // `*const T`, and that declaration is why.
            var unsafe *sx = dyn_cast<SubscriptExpr>(x)
            if (!at.is_valid()) && sx != &null && sx->resolved_op != &null {
                b.note(sx->resolved_op->range.start, "\x27op []\x27 returns a const place here")
                    ->first(sx->resolved_op->range)
            }

            // `const n = ...` -> `var n = ...` is the one-token edit; a
            // parameter's or a pointee's const has no keyword range recorded.
            if (by_decl || by_owner)
                && vd != &null
                && vd->storage == StorageClass::Const
                && vd->storage_kw.is_valid() {
                b.fix(vd->storage_kw, "var", "declare it with \x27var\x27 to make it assignable")
            }

            b.emit()
        }

        n->poison()
        return true
    }

    /// \p d's type as written, or null: what a fix-it on its slot edits.
    priv fn _written_type_of(self, d: unsafe *Decl) -> unsafe *Type {
        if d == &null {
            return &null
        }

        var unsafe *v = dyn_cast<VariableDecl>(d)
        if v != &null {
            return v->type_
        }

        var unsafe *p = dyn_cast<ParamDecl>(d)
        if p != &null {
            return p->type_
        }

        var unsafe *f = dyn_cast<FieldDecl>(d)
        if f != &null {
            return f->type_
        }

        return &null
    }

    fn type_assign(self, n: unsafe *AssignOperatorExpr, expected: unsafe *Type) -> unsafe *Type {
        var k  = n->op_token.kind
        var lt = self.dyn()->type_of(n->lhs, &null)
        if self.dyn()->propagate(n, n->lhs) || lt == &null {
            // A left side whose type is unknown (a dependent `res[i]`) must
            // not leave the right side unvisited: a brace initializer there
            // would reach codegen untyped (O4).
            // A bare `&null` has no pointer type to take from the unknown
            // left side: left untyped it goes out as `nullptr`, which
            // converts to the member's pointer in each instance. Typed
            // against nothing it would be SC076E.
            var nl = dyn_cast<NullLiteralExpr>(self.dyn()->tu.strip_parens(n->rhs))
            if nl != &null && nl->is_ref {
                self.dyn()->mark_unknown(n->rhs)
            } else {
                self.dyn()->type_of(n->rhs, &null)
            }

            return &null
        }

        // The assigned-to object, not the reference naming it: `v.at(i) = 5`
        // assigns an `i32`. The lvalue test below still reads the NODE's
        // category, which _default_category already set to LValue for a `T&`
        // result, so the reference stays assignable.
        lt = self.dyn()->tu.as_value(lt)

        if !self.dyn()->is_lvalue(n->lhs) {
            self.dyn()->fail(n, DiagID::SC071E, "left side of assignment is not assignable")
            self.dyn()->type_of(n->rhs, &null)
            return &null
        }

        // A record's own `op +=` decides for itself (its `const self`, or
        // not); every other write to a const place stops here.
        if k == TokenKind::OpEqual
            || self.dyn()->tu.kind_of(lt) != BuiltinKind::COUNT
            || self.dyn()->tu.pointee(lt) != &null {
            var verb = "update"
            if k == TokenKind::OpEqual {
                verb = "assign to"
            }

            if self._reject_const_write(n, n->lhs, verb) {
                // The right side is still typed (a brace initializer must
                // not reach codegen untyped, O4), against the place's type;
                // a bare `null` there has no target to take a type from and
                // would add SC076E to the one real error.
                if isa<NullLiteralExpr>(self.dyn()->tu.strip_parens(n->rhs)) {
                    self.dyn()->mark_unknown(n->rhs)
                } else {
                    self.dyn()->type_of(n->rhs, lt)
                }

                return &null
            }
        }

        if k == TokenKind::OpEqual {
            var lc = canon_unqual(lt)
            if lc != &null && isa<FixedArrayType>(lc) && !self._ctor_field_write(n) {
                self.dyn()->type_of(n->rhs, lt)
                self.dyn()->fail(
                    n,
                    DiagID::SC071E,
                    "an array is not assignable; assign its elements, or go through a slice",
                )

                return &null
            }

            var unsafe *ad = self._assigned_decl(n->lhs)
            self.dyn()->push_null_target(n->rhs, self._written_type_of(ad), ad)
            self.dyn()->type_of(n->rhs, lt)
            self.dyn()->pop_null_target()
            if self.dyn()->propagate(n, n->rhs) {
                return &null
            }

            if self.dyn()->reject_slice_literal(n->rhs, "assigned to a slice") {
                self.dyn()->poison_only(n)
                return &null
            }

            if !self.dyn()->check_convertible(n->rhs, lt) {
                self.dyn()->poison_only(n)
                return &null
            }

            n->value_category = Expr::ValueCategory::LValue
            // The value SETS the place's state (Compiler/Spec/Nullables.md#definitions-and-conditions).
            self.dyn()->flow.assign(n->lhs, n->rhs, n->range)
            return lt
        }

        // compound: `a += b` reads both values (Compiler/Spec/Nullables.md#narrowed-reads); a narrowed
        // `a` is written through, so it stays proven.
        if self.dyn()->tu.nullable_inner(lt) != &null {
            var nl = self.dyn()->read_value(n->lhs)
            if nl == &null {
                self.dyn()->poison_only(n)
                self.dyn()->type_of(n->rhs, &null)
                return &null
            }

            lt = self.dyn()->tu.as_value(nl)
        }

        // compound: the underlying binary op's rules, converting the RIGHT
        // operand only (§6).
        var base = OperatorFacts::compound_base(k)
        var rt   = self.dyn()->type_of(n->rhs, lt)
        if rt == &null && self.dyn()->reject_type_value(n->rhs) {
            self.dyn()->poison_only(n)
            return &null
        }

        if self.dyn()->propagate(n, n->rhs) {
            return &null
        }

        if rt == &null {
            return &null
        }

        rt = self.dyn()->tu.as_value(rt)
        if self.dyn()->tu.nullable_inner(rt) != &null {
            var nr = self.dyn()->read_value(n->rhs)
            if nr == &null {
                self.dyn()->poison_only(n)
                return &null
            }

            rt = self.dyn()->tu.as_value(nr)
        }

        // `p += n` / `p -= n`: the binary rule's pointer offset, written
        // back (_type_pointer_op). Ahead of the deferral for the same reason.
        if self.dyn()->tu.pointee(lt) != &null
            && (base == TokenKind::OpPlus || base == TokenKind::OpMinus)
            && self.dyn()->tu.is_integer(rt) {
            if self.dyn()->tu.is_void(self.dyn()->tu.pointee(lt)) {
                self.dyn()->fail(
                    n,
                    DiagID::SC067E,
                    f"pointer arithmetic moves in units of the pointee, and '{self.dyn()->tu.str(lt)}' points to void; cast it to a typed pointer first",
                )

                return &null
            }

            n->value_category = Expr::ValueCategory::LValue
            return lt
        }

        // A bounded parameter on the left binds through its bounds, as in
        // the binary case; any other dependent operand defers.
        if (self._is_dependent(lt) || self._is_dependent(rt)) && !self._bounded(lt) {
            var cg = self.dyn()->tu.op_checked_head(lt)
            if cg == &null {
                self.dyn()->mark_unknown(n)
                return &null
            }

            self.dyn()->needs_bound(n, cg, false, self._compound_msg(n, lt, base))
            return &null
        }

        var l_rec = self.dyn()->tu.kind_of(lt) == BuiltinKind::COUNT
        var r_rec = self.dyn()->tu.kind_of(rt) == BuiltinKind::COUNT
        if l_rec || r_rec {
            var t = self._type_compound(n, k, base, lt, rt)
            if t != &null || n->is_poisoned() || n->is_instantiation_dependent() {
                return t
            }

            // Primitive left, record right, nothing declared: the builtin
            // checks below say what is wrong with it.
        }

        if self._is_shift(base) {
            if !self.dyn()->tu.is_integer(lt) || !self.dyn()->tu.is_integer(rt) {
                self.dyn()->fail(n, DiagID::SC067E, "shift-assignment operands must be integers")
                return &null
            }

            n->no_wrap = self._shift_count(n, n->rhs, lt)
            if n->is_poisoned() {
                return &null
            }
        } else if self._is_bitwise(base) {
            var ok = self.dyn()->tu.is_integer(lt) && self.dyn()->tu.is_integer(rt)
                || self.dyn()->tu.is_bool(lt) && self.dyn()->tu.is_bool(rt)
                || self.dyn()->tu.is_builtin(lt, BuiltinKind::Byte)
                    && self.dyn()->tu.is_builtin(rt, BuiltinKind::Byte)
            if !ok {
                self.dyn()->fail(
                    n,
                    DiagID::SC067E,
                    f"bitwise assignment is not defined for '{self.dyn()->tu.str(lt)}' and '{self.dyn()->tu.str(rt)}'",
                )

                return &null
            }

            if !self.dyn()->check_convertible(n->rhs, lt) {
                self.dyn()->poison_only(n)
                return &null
            }
        } else {
            if !self.dyn()->tu.is_numeric(lt) || !self.dyn()->tu.is_numeric(rt) {
                self.dyn()->fail(
                    n,
                    DiagID::SC067E,
                    f"arithmetic assignment is not defined for '{self.dyn()->tu.str(lt)}' and '{self.dyn()->tu.str(rt)}'",
                )

                return &null
            }

            if !self.dyn()->check_convertible(n->rhs, lt) {
                self.dyn()->poison_only(n)
                return &null
            }
        }

        n->value_category = Expr::ValueCategory::LValue
        return lt
    }

    /// `a += b` with a record on either side. ONE definition per pair: the
    /// type's `op +=` if it declares one, else its `op +` with `a = a + b`
    /// semantics (OperatorLowering renders either from resolved_op). Both
    /// applying is the rule broken across scopes. An imported C++ type gets
    /// exactly what C++ declares. The expression is a statement: void.
    ///
    /// Returns null with the node untouched when nothing at all applies and
    /// the left side is primitive, so the builtin checks report it.
    /// `a += b` on a bounds-checked parameter: granted by an `op +=`
    /// requirement, or derived from an `op +` one.
    priv fn _compound_msg(self,
                          n:    *AssignOperatorExpr,
                          lt:   unsafe *Type,
                          base: TokenKind) -> string {
        var sym  = self.dyn()->sc->ctx->get_spelling(n->op_token)
        var bsym = token_kind_to_readable_string(base)
        return f"'{sym}' on '{self.dyn()->tu.head_spelling(lt)}' needs a bound that declares 'op {sym}' or 'op {bsym}'"
    }

    priv fn _type_compound(self,
                           n:    *AssignOperatorExpr,
                           k:    TokenKind,
                           base: TokenKind,
                           lt:   unsafe *Type,
                           rt:   unsafe *Type) -> unsafe *Type {
        var l_rec   = self.dyn()->tu.kind_of(lt) == BuiltinKind::COUNT
        var foreign = l_rec && decl_is_imported(self.dyn()->tu.record_decl(lt))

        var c_cands = cxx::std::vector<unsafe *Decl>()
        var c_frees = cxx::std::vector<unsafe *Decl>()
        var b_cands = cxx::std::vector<unsafe *Decl>()
        var b_frees = cxx::std::vector<unsafe *Decl>()
        self._gather(
            DeclName::op_name(k, TokenKind::TkUnknown),
            lt,
            rt,
            -1,
            unsafe &c_cands,
            unsafe &c_frees,
        )

        if !foreign {
            self._gather(
                DeclName::op_name(base, TokenKind::TkUnknown),
                lt,
                rt,
                -1,
                unsafe &b_cands,
                unsafe &b_frees,
            )
        }

        var has_c = c_cands.size() > 0 || c_frees.size() > 0
        var has_b = b_cands.size() > 0 || b_frees.size() > 0

        if has_c && has_b {
            var bsp = self.dyn()->sc->ctx->get_spelling(n->op_token)
            self.dyn()->sc->diag->report(
                DiagID::SC035E,
                n->range.start,
                f"both an 'op {bsp}' and its base operator apply to '{self.dyn()->tu.str(lt)}'; a type declares one and the other is derived from it",
            ).first(n->range)->emit()
            n->poison()
            return &null
        }

        if !(has_c || has_b) {
            if self._bounded(lt) {
                // Nothing in the bounds: an error on a bounds-checked
                // parameter (D0), else deferred as before.
                var cg = self.dyn()->tu.op_checked_head(lt)
                if cg == &null {
                    self.dyn()->mark_unknown(n)
                    return &null
                }

                self.dyn()->needs_bound(n, cg, true, self._compound_msg(n, lt, base))
                return &null
            }

            if !l_rec {
                return &null
            }

            self.dyn()->fail(
                n,
                DiagID::SC066E,
                f"no operator '{self.dyn()->sc->ctx->get_spelling(n->op_token)}' on '{self.dyn()->tu.str(lt)}'",
            )

            return &null
        }

        var found = false
        var args  = cxx::std::vector<unsafe *Expr>()
        args.push_back(n->rhs)
        var rk = if (has_c) => (k) else => base
        var unsafe *ut = self.resolve_user_op(
            unsafe (n as unsafe *Expr),
            rk,
            TokenKind::TkUnknown,
            n->lhs,
            lt,
            rt,
            args,
            -1,
            self._label(n->op_token),
            unsafe &found,
        )

        if n->is_poisoned() || n->is_instantiation_dependent() {
            return &null
        }

        if has_b {
            // `a = a + b`: the sum must be assignable to a. The rule is `=`'s
            // (an implicit conversion); a converting constructor is not one.
            if ut != &null
                && self.dyn()->conv.implicit(
                    self.dyn()->tu.as_value(ut),
                    canon_unqual(lt),
                ) == ImplicitRank::None {
                self.dyn()->fail(
                    n,
                    DiagID::SC072E,
                    f"'op {self.dyn()->sc->ctx->get_spelling(n->op_token)}' derived from the base operator would assign a '{self.dyn()->tu.str(ut)}' to a '{self.dyn()->tu.str(lt)}'",
                )

                return &null
            }
        }

        n->value_category = Expr::ValueCategory::RValue
        return self.dyn()->tu.builtin(BuiltinKind::Void)
    }
}
