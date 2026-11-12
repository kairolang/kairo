/// --- The Kairo Project ------------- Sema/Check/ConformanceChecking.k --- ///
///
///   \brief Interface conformance at the instantiation site, and the
///          conformance table it fills.
///
///   \detail
///     Compiler/Spec/Generics.md#partial-selection, "The conformance table". Wherever a generic's
///     `P impl I` bound meets a concrete argument X, `conforms(X, I)` finds
///     the ROW: for each of I's own requirements, the decl on X that
///     implements it -- an own or inherited member, an extension member, an
///     imported C++ member, whatever member lookup on X finds. The rows go
///     on the instance (`InstanceEntry::rows`, bound order, then each bound
///     interface's `derives` closure), which is the whole input of EmitPlan's
///     witness-specialization edge (Compiler/Spec/Witnesses.md#emission).
///
///     A requirement matches a candidate on the requirement's signature as
///     the conformer sees it: `Self` replaced by X (Deduction::replace_self),
///     the interface's own parameters by the bound's arguments. Exact, on
///     canonicals: the same receiver constness, the same parameter count,
///     modes and types, the same return type. Exact because the witness
///     forwards to the decl the row names and must reach the same one in
///     every TU (Compiler/Spec/Witnesses.md#the-c-shape); a looser match is a different design.
///     A constructor requirement is the exception to looking up by name:
///     X's own constructors are, named after X (_ctor_implementation).
///
///     A row is shared build-wide (the registry's table): a row TU A found
///     is the one every TU holding the same instance reads, and an
///     instance's rows are the union over every TU that checked it (Compiler/Spec/Generics.md
///     D7), so every TU's C++ carries the same ones. Which rows a TU's own
///     checks may USE is a per-TU filter, the extension-visibility rule: a
///     row whose extension members are outside the TU's extension-visible
///     set (its imports and what they re-export) is not this TU's (`_usable`; ConformanceRow::seen_by), and a use
///     here is checked against what this TU sees, even of an instance
///     another TU made live first (`_recheck`). The row is
///     STRUCTURAL -- found at this use -- or DECLARED, found at the `impl`
///     declaration (`class X impl I`, `extend X impl I`) and recorded
///     under it for EmitPlan (visit_decl). A generic declared conformance
///     is one row over the declaring decl's own parameters, and a concrete
///     row it covers says so (_covering). The impl-only rule and extension
///     visibility are this pass's too and are not built yet: a declared row
///     that does not hold is not reported.
///
///   Phase: CHECK, after ExprTyper (it reads every call's registered
///   instance).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "vector"

import AST::ASTSupport::{
    FrozenList,
    create_empty_frozen_list,
}
import AST::Context::DeclContext::DeclContext
import AST::Context::InstantiationRegistry::{
    ConformanceRow,
    InstanceEntry,
    InstanceLatch,
    PartialPredValue,
}
import AST::Context::SymbolTable::DeclName
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts::{
    decl_extension_of, decl_generic_params, decl_is_ctor_requirement, decl_is_imported,
    decl_is_instance,  decl_name_tok,       decl_pattern,             decl_requires_clause,
}
import AST::Kind::ExprKind::ExprKind
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::{
    AllocNames,
    GlobalAllocFn,
    WellKnownType,
}
import AST::Mixin::Annotation::VisibilityKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,
    BuiltinKind,
    BuiltinType,
    RecordType,
    canon_unqual,
    is_c_character,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions::{
    AlignOfExpr, BinaryOperatorExpr, CallExpr,      ConstraintExpr,    PackExpansionExpr, ParenExpr,
    SizeOfExpr,  TypeTraitExpr,      TypeTraitKind, UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr,
    ChainExpr,
    IntegerLiteralExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Types::{
    CXXLValueRefType, CXXRValueRefType, ChainType, FixedArrayType, GenericParamType, NullableType,
    PointerType,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::DiagBuilder::DiagBuilder
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Check::ClassLifecycle::{
    LifecycleCategory,
    LifecycleFailure,
    LifecycleTri,
    lifecycle_of,
}
import Sema::Resolve::MemberLookup::{
    MemberLookup,
    extension_visible,
}
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::ArgumentDeduction::Deduction
import Sema::Type::Conversion::ImplicitRank
import Sema::Type::Substitution::Substitution
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

/// The dependent uses in a generic body that name instances of their own
/// once the body's parameters are known: calls whose callee's arguments are
/// still dependent (CallExpr::dep_args), and dependent record types.
/// Collected, not checked: ConformanceChecking substitutes and checks them
/// per instance of the enclosing generic.
pub class _NestedUses derives RecursiveASTVisitor<_NestedUses> {
    pub var calls: cxx::std::vector<unsafe *CallExpr>
    pub var types: cxx::std::vector<unsafe *Type>
    /// Parallel to `types`: where each was found, the hop note's place.
    pub var type_at: cxx::std::vector<SourceRange>
    fn _NestedUses(self) { }

    fn visit_expr(self, e: unsafe *Expr) -> bool {
        if e == &null || e->is_poisoned() {
            return true
        }

        if e->type_ != &null && e->type_->is_dependent() {
            self.types.push_back(e->type_)
            self.type_at.push_back(e->range)
        }

        if e->kind != ExprKind::CallExpr {
            return true
        }

        var unsafe *c = cast<CallExpr>(e)
        if c->dep_args.size() > 0 {
            self.calls.push_back(c)
        }

        return true
    }

    fn visit_type(self, t: unsafe *Type) -> bool {
        if t != &null && t->is_dependent() {
            self.types.push_back(t)
            self.type_at.push_back(t->range)
        }

        return true
    }
}

/// A requires-clause predicate known false, and the type whose missing
/// copy made it so, when one predicate names it (else null).
pub struct PredFalse {
    pub var known:   bool         = false
    pub var blocker: unsafe *Type = &null
}

/// ConformanceChecking::dropped_copy: the record's `@copy` constructor an
/// instance loses to its `requires` (null when the instance keeps its
/// copy), and the type argument that cannot be copied (null when no
/// predicate names one).
pub struct DroppedCopy {
    pub var ctor:    unsafe *Declarations::FunctionDecl = &null
    pub var element: unsafe *Type                       = &null
}

pub class ConformanceChecking derives RecursiveASTVisitor<ConformanceChecking> {
    pub var  sc: unsafe *SemaContext
    priv var tu: TypeUtil
    priv var ml: MemberLookup

    fn ConformanceChecking(self, sc: unsafe *SemaContext) {
        self.sc = sc
        self.tu = TypeUtil(sc)
        self.ml = MemberLookup(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved)
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
            return
        }

        self.ml.index_extensions()
        self._indexed = true
        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            var item = *items->get(i)
            match item.get_kind() {
                case TopLevelKind::Decl {
                    self.dyn()->dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dyn()->dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dyn()->dispatch_expr(item.as_expr())
                }
            }
        }

        for var i: usize = 0; i < self._rangeless.size(); ++i {
            self._check_instance(self._rangeless[i], self._rangeless_at[i])
        }

        // What the instances this TU uses reach, to the fixpoint: their
        // nonconformance is this TU's to report, beside its own.
        self.discover()
        self._check_global_allocator()
    }

    /// `@set_global_allocator(A)`: A is a class or struct with the five
    /// static functions the strong `kairo_global_*` forwarders call
    /// (EmitIR::_global_allocator), each found by name. Their signatures
    /// are checked by clang against the forwarders: the interface
    /// they make up (FullAllocator) lives in the builtin, which this TU
    /// cannot name from here. Without this, a missing one is a clang error
    /// in generated code.
    priv fn _check_global_allocator(self) {
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->global_alloc == &null {
            return
        }

        var unsafe *ta = dyn_cast<Declarations::TypeAliasDecl>(tu->global_alloc)
        if ta == &null || ta->aliased == &null || ta->aliased->is_poisoned() {
            return
        }

        var        at = tu->global_alloc_at
        var unsafe *c = canon_unqual(ta->aliased->canonical)
        if c == &null { // T reported the name.
            return
        }

        var unsafe *rd = if (isa<RecordType>(c)) => (cast<RecordType>(c)->decl) else => &null
        if rd == &null
            || (!isa<Declarations::ClassDecl>(rd)) && !isa<Declarations::StructDecl>(rd) {
            var b = self.sc->diag->report(
                DiagID::SC141E,
                at.start,
                f"'{self.tu.str(c)}' cannot be the global allocator: only a class or struct with static allocator functions can",
            )

            b.first(ta->aliased->range)
            b.emit()
            return
        }

        var names = cxx::std::vector<string>()
        for var k: usize = 0; k < (GlobalAllocFn::COUNT as u8 as usize); ++k {
            names.push_back(
                AllocNames::global_alloc_member((k as u8) as GlobalAllocFn),
            )
        }

        var unsafe *imms = self.sc->ctx->get_imm_table()
        if imms == &null {
            return
        }

        for var i: usize = 0; i < names.size(); ++i {
            var cands = cxx::std::vector<unsafe *Decl>()
            self.ml.lookup(
                c,
                DeclName::ident(imms->intern_ident_copy(names[i])),
                unsafe &cands,
            )

            var found = false
            for var j: usize = 0; j < cands.size(); ++j {
                var unsafe *f = dyn_cast<Declarations::FunctionDecl>(cands[j])
                if f != &null && !f->is_method() {
                    found = true
                    break
                }
            }

            if found {
                continue
            }

            var b = self.sc->diag->report(
                DiagID::SC141E,
                at.start,
                f"'{self.tu.str(c)}' cannot be the global allocator: it has no static function '{names[i]}'",
            )

            b.first(ta->aliased->range)
            b.note(
                DiagCode(DiagID::SC141N),
                rd->range.start,
                "the global allocator needs static alloc, free, resize, realloc and alloc_zeroed (FullAllocator)",
            )->child_first(rd->range)
            b.emit()
        }
    }

    fn visit_expr(self, e: unsafe *Expr) -> bool {
        if e == &null || e->is_poisoned() {
            return true
        }

        if e->range.start.is_valid() {
            self._cur_at = e->range
        }

        // A bounded record's instance is an instantiation site wherever its
        // type turns up: written, inferred, or as an argument of another.
        if e->type_ != &null {
            self._check_type(e->type_, e->range, 0)
        }

        if e->kind != ExprKind::CallExpr {
            self._check_fn_value(e)
            return true
        }

        var unsafe *c  = cast<CallExpr>(e)
        var unsafe *ie = c->instance
        if ie != &null {
            self._check_instance(ie, c->range)
        }

        self._check_qualified(c)
        self._check_member_requires(c)
        return true
    }

    /// # a generic record's member `requires` at a call

    /// A call of a generic record's method whose `requires` has value
    /// predicates, on a concrete instance: each predicate at the receiver's
    /// arguments, and a false one is the error here, in Kairo's words.
    /// Codegen spells the predicates as the member's trailing C++ clause
    /// (CXXSpell::member_requires), which is what refuses a call this
    /// cannot decide -- a record's layout, a trait only C++ answers.
    priv fn _check_member_requires(self, c: unsafe *CallExpr) {
        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(self._callee_of(c))
        if f == &null {
            return
        }

        var unsafe *fr = dyn_cast<Declarations::FunctionDecl>(
            NameLookup::representative(unsafe (f as unsafe *Decl)),
        )

        if fr != &null {
            f = fr
        }

        if f->requires_clause == &null || f->generic_params.size() > 0 || !f->is_method() {
            return
        }

        var unsafe *ch = dyn_cast<ChainExpr>(self.tu.strip_parens(c->callee))
        if ch == &null || ch->steps.size() == 0 {
            return
        }

        var rt: unsafe *Type = &null
        if ch->steps.size() >= 2 {
            rt = ch->steps.get(ch->steps.size() - 2)->resolved_type
        } else if ch->base != &null {
            rt = ch->base->type_
        }

        var unsafe *rec = self._receiver_record(rt)
        if rec == &null {
            return
        }

        var d = Deduction(self.sc, &null)
        d.bind_from_record(rec)
        var vps = cxx::std::vector<unsafe *Expr>()
        self._value_preds(f->requires_clause, unsafe &vps)
        for var i: usize = 0; i < vps.size(); ++i {
            var v = self._vp(vps[i], unsafe &d, 0)
            if !v.known || v.v != 0 {
                continue
            }

            var rs    = self.tu.str(rec)
            var fname = self.tu.decl_name(unsafe (f as unsafe *Decl))
            var b = self.sc->diag->report(
                DiagID::SC153E,
                c->range.start,
                f"'{fname}' cannot be called on '{rs}': its 'requires' clause does not hold",
            )

            b.first(c->range)
            b.note(
                DiagCode(DiagID::SC153N),
                vps[i]->range.start,
                f"this is false for '{rs}'",
            )->child_first(vps[i]->range)
            b.emit()
            return
        }
    }

    /// The concrete record a method is called on, through pointers,
    /// references and `?`; null for anything else or a dependent one.
    priv fn _receiver_record(self, t: unsafe *Type) -> unsafe *Type {
        var unsafe *c     = self._canon(t)
        var        n: u32 = 0
        while c != &null && n < 8 {
            n += 1
            if isa<PointerType>(c) {
                c = self._canon(cast<PointerType>(c)->pointee)
                continue
            }

            if isa<CXXLValueRefType>(c) {
                c = self._canon(cast<CXXLValueRefType>(c)->referee)
                continue
            }

            if isa<CXXRValueRefType>(c) {
                c = self._canon(cast<CXXRValueRefType>(c)->referee)
                continue
            }

            if isa<NullableType>(c) {
                c = self._canon(cast<NullableType>(c)->inner)
                continue
            }

            break
        }

        if c == &null
            || !isa<RecordType>(c)
            || c->is_dependent()
            || c->is_instantiation_dependent() {
            return &null
        }

        return c
    }

    /// The value conjuncts of clause \p e (not `impl` / `derives`).
    priv fn _value_preds(self, e: unsafe *Expr, out: unsafe *cxx::std::vector<unsafe *Expr>) {
        if e == &null {
            return
        }

        var unsafe *b = dyn_cast<BinaryOperatorExpr>(e)
        if b != &null
            && (b->op_token.kind == TokenKind::OpAmpAmp || b->op_token.kind == TokenKind::KwAnd) {
            self._value_preds(b->lhs, out)
            self._value_preds(b->rhs, out)
            return
        }

        if isa<ConstraintExpr>(e) {
            return
        }

        out->push_back(e)
    }

    /// Predicate \p e under \p d: literals, `!` `&&` `||`, comparisons and
    /// integer arithmetic, `sizeof` / `alignof` of a builtin or a pointer,
    /// and the trivially-copyable / -destructible facts (`is_..!(T)` and the
    /// `__builtin_is_...<T>()` lang items), from ClassLifecycle. Anything
    /// else is unknown (InstantiationRegistry::requires_holds is the same
    /// shape for a partial's clause).
    priv fn _vp(self, e: unsafe *Expr, d: unsafe *Deduction, depth: u32) -> PartialPredValue {
        var out = PartialPredValue{}
        if e == &null || depth > 64 {
            return out
        }

        if isa<ParenExpr>(e) {
            return self._vp(cast<ParenExpr>(e)->inner, d, depth + 1)
        }

        if isa<BooleanLiteralExpr>(e) {
            out.known = true
            out.v     = if (cast<BooleanLiteralExpr>(e)->value) => (1) else => 0
            return out
        }

        if isa<IntegerLiteralExpr>(e) {
            var unsafe *il = cast<IntegerLiteralExpr>(e)
            if il->get_value_hi() != 0 || il->get_value_lo() > (9223372036854775807 as u64) {
                return out
            }

            out.known = true
            out.v     = (il->get_value_lo() as i64)
            return out
        }

        if isa<SizeOfExpr>(e) || isa<AlignOfExpr>(e) {
            var is_size = isa<SizeOfExpr>(e)
            var unsafe *ta = if (is_size) => (cast<SizeOfExpr>(e)->type_arg)
                             else => cast<AlignOfExpr>(e)->type_arg
            var unsafe *s = self._subst(ta, d)
            if s == &null || (!isa<BuiltinType>(s)) && !isa<PointerType>(s) {
                return out
            }

            if isa<BuiltinType>(s) && cast<BuiltinType>(s)->lang_decl != &null {
                return out
            }

            if s->size_bits == 0 || s->align_bits == 0 || s->size_bits % 8 != 0 {
                return out
            }

            out.known = true
            out.v     = ((if (is_size) => (s->size_bits / 8) else => s->align_bits / 8) as i64)
            return out
        }

        if isa<TypeTraitExpr>(e) {
            var unsafe *tt = cast<TypeTraitExpr>(e)
            return self._trait(
                self._subst(tt->type_arg, d),
                tt->fact == TypeTraitKind::TriviallyCopyable,
            )
        }

        if isa<CallExpr>(e) {
            var unsafe *c      = cast<CallExpr>(e)
            var unsafe *callee = self._callee_of(c)
            if callee == &null || c->args.size() != 0 {
                return out
            }

            var copyable = self._is_lang(
                callee,
                WellKnownType::IsTriviallyCopyable,
            )

            if !copyable && !self._is_lang(callee, WellKnownType::IsTriviallyDestructible) {
                return out
            }

            var unsafe *ni = dyn_cast<NamedIdentExpr>(
                self.tu.strip_parens(c->callee),
            )

            if ni == &null || ni->generic_args.size() != 1 {
                return out
            }

            return self._trait(
                self._subst(ni->generic_args.get(0)->ty, d),
                copyable,
            )
        }

        if isa<UnaryOperatorExpr>(e) {
            var unsafe *u = cast<UnaryOperatorExpr>(e)
            var        x  = self._vp(u->operand, d, depth + 1)
            if !x.known {
                return out
            }

            var k = u->op_token.kind
            if k == TokenKind::OpExclaim || k == TokenKind::KwNot {
                out.known = true
                out.v     = if (x.v == 0) => (1) else => 0
                return out
            }

            if k == TokenKind::OpMinus {
                out.known = true
                out.v     = (0 as i64) - x.v
                return out
            }

            if k == TokenKind::OpPlus {
                return x
            }

            return out
        }

        if isa<BinaryOperatorExpr>(e) {
            var unsafe *bn = cast<BinaryOperatorExpr>(e)
            var        k   = bn->op_token.kind
            var        l   = self._vp(bn->lhs, d, depth + 1)
            if k == TokenKind::OpAmpAmp || k == TokenKind::KwAnd {
                if l.known && l.v == 0 {
                    out.known = true
                    out.v     = 0
                    return out
                }

                var r = self._vp(bn->rhs, d, depth + 1)
                if r.known && r.v == 0 {
                    out.known = true
                    out.v     = 0
                    return out
                }

                if l.known && r.known {
                    out.known = true
                    out.v     = 1
                }

                return out
            }

            if k == TokenKind::OpPipePipe || k == TokenKind::KwOr {
                if l.known && l.v != 0 {
                    out.known = true
                    out.v     = 1
                    return out
                }

                var r = self._vp(bn->rhs, d, depth + 1)
                if r.known && r.v != 0 {
                    out.known = true
                    out.v     = 1
                    return out
                }

                if l.known && r.known {
                    out.known = true
                    out.v     = 0
                }

                return out
            }

            var r = self._vp(bn->rhs, d, depth + 1)
            if !l.known || !r.known {
                return out
            }

            out.known = true
            if k == TokenKind::OpLess {
                out.v = if (l.v < r.v) => (1) else => 0
                return out
            }

            if k == TokenKind::OpLessEqual {
                out.v = if (l.v <= r.v) => (1) else => 0
                return out
            }

            if k == TokenKind::OpGreater {
                out.v = if (l.v > r.v) => (1) else => 0
                return out
            }

            if k == TokenKind::OpGreaterEqual {
                out.v = if (l.v >= r.v) => (1) else => 0
                return out
            }

            if k == TokenKind::OpEqualEqual {
                out.v = if (l.v == r.v) => (1) else => 0
                return out
            }

            if k == TokenKind::OpExclaimEqual {
                out.v = if (l.v != r.v) => (1) else => 0
                return out
            }

            if k == TokenKind::OpPlus {
                out.v = l.v + r.v
                return out
            }

            if k == TokenKind::OpMinus {
                out.v = l.v - r.v
                return out
            }

            if k == TokenKind::OpStar {
                out.v = l.v * r.v
                return out
            }

            out.known = false
            return out
        }

        return out
    }

    /// \p t with \p d's bindings, canonical, or null while still dependent.
    priv fn _subst(self, t: unsafe *Type, d: unsafe *Deduction) -> unsafe *Type {
        if t == &null || t->canonical == &null {
            return &null
        }

        var unsafe *s = d->substitute(t->canonical)
        if s == &null {
            return &null
        }

        var unsafe *c = self._canon(s)
        if c == &null || c->is_dependent() || c->is_instantiation_dependent() {
            return &null
        }

        return c
    }

    /// A triviality fact of concrete \p t, from ClassLifecycle.
    priv fn _trait(self, t: unsafe *Type, copyable: bool) -> PartialPredValue {
        var out = PartialPredValue{}
        if t == &null {
            return out
        }

        var f = lifecycle_of(self.sc)->facts_of_type_concrete(
            t,
            "ConformanceChecking",
        )

        var x = if (copyable) => (f.trivially_copyable) else => f.trivial_dtor
        if x == LifecycleTri::Unknown {
            return out
        }

        out.known = true
        out.v     = if (x == LifecycleTri::Yes) => (1) else => 0
        return out
    }

    priv fn _is_lang(self, d: unsafe *Decl, k: WellKnownType) -> bool {
        if d == &null || self.sc->well_known == &null {
            return false
        }

        var unsafe *ld = self.sc->well_known->get(k)
        return ld != &null && NameLookup::representative(d) == NameLookup::representative(ld)
    }

    fn visit_type(self, t: unsafe *Type) -> bool {
        if t != &null && t->range.start.is_valid() {
            self._cur_at = t->range
        }

        if t != &null {
            self._check_type(t, t->range, 0)
        }

        if t != &null && t->canonical != &null && isa<AssocType>(canon_unqual(t->canonical)) {
            self._check_assoc_args(
                cast<AssocType>(canon_unqual(t->canonical)),
                t->range,
            )
        }

        return true
    }

    /// A generic associated type named at concrete arguments (`T::Map<i32>`
    /// of `type <K impl Hashable> Map`): each meets its parameter's bounds,
    /// as a generic record's arguments do. A dependent argument is its own
    /// declaration's to bound.
    priv fn _check_assoc_args(self, a: unsafe *AssocType, at: SourceRange) {
        var unsafe *ta = dyn_cast<Declarations::TypeAliasDecl>(a->assoc)
        if ta == &null || a->args.size() == 0 {
            return
        }

        for var k: usize = 0; k < a->args.size() && k < ta->generic_params.size(); ++k {
            var unsafe *x = canon_unqual(a->args[k])
            if x == &null || x->is_dependent() || x->is_instantiation_dependent() {
                continue
            }

            var bs = cxx::std::vector<unsafe *ConstraintExpr>()
            self.tu.assoc_param_bounds(ta, k, &bs)
            for var i: usize = 0; i < bs.size(); ++i {
                var unsafe *c = bs[i]
                if c->rhs == &null || c->rhs->canonical == &null {
                    continue
                }

                var unsafe *iface = canon_unqual(c->rhs->canonical)
                if iface->is_dependent() {
                    continue
                }

                var unsafe *row = self.conforms(x, iface)
                if row == &null || row->ok {
                    continue
                }

                self._report(at, c, x, iface, row)
                return
            }
        }
    }

    fn visit_decl(self, d: unsafe *Decl) -> bool {
        if d == &null || d->is_poisoned() {
            return true
        }

        if d->range.start.is_valid() {
            self._cur_at = d->range
        }

        if isa<Declarations::ClassDecl>(d) {
            var unsafe *cd = cast<Declarations::ClassDecl>(d)
            for var i: usize = 0; i < cd->implements.size(); ++i {
                self._check_declared(
                    d,
                    self._self_type(d),
                    cd->implements.get(i)->base,
                )
            }
        } else if isa<Declarations::StructDecl>(d) {
            var unsafe *sd = cast<Declarations::StructDecl>(d)
            for var i: usize = 0; i < sd->implements.size(); ++i {
                self._check_declared(
                    d,
                    self._self_type(d),
                    sd->implements.get(i)->base,
                )
            }
        } else if isa<Declarations::ExtensionDecl>(d) {
            var unsafe *x = cast<Declarations::ExtensionDecl>(d)
            var unsafe *t = if (x->target != &null) => (self._canon(x->target)) else => &null
            for var i: usize = 0; i < x->implements.size(); ++i {
                self._check_declared(d, t, x->implements.get(i)->base)
            }
        } else if isa<Declarations::InterfaceDecl>(d) {
            self._check_assoc_defaults(cast<Declarations::InterfaceDecl>(d))
        }

        return true
    }

    /// interfaces.md, Defaults: "a default must satisfy its own bounds,
    /// checked once, at the interface declaration, with Self abstract". A
    /// concrete default by conformance; a default that is another
    /// associated type (`= Self::Node`) by that type's own bounds, all it is
    /// known to have while Self is abstract. Any other default naming Self
    /// (`(Self::Node, Self::Node)`) is not decided here (no conformance
    /// question can be asked of it before a conformer exists).
    priv fn _check_assoc_defaults(self, id: unsafe *Declarations::InterfaceDecl) {
        if id->compose_state != 2 {
            return
        }

        for var j: usize = 0; j < id->requirements.size(); ++j {
            var unsafe *rq = id->requirements.get(j)
            if rq->leaf != u32::MAX {
                continue
            }

            var unsafe *ta = dyn_cast<Declarations::TypeAliasDecl>(rq->decl)
            if ta == &null
                || ta->is_poisoned()
                || ta->aliased == &null
                || ta->aliased->canonical == &null {
                continue
            }

            var unsafe *dflt  = canon_unqual(ta->aliased->canonical)
            var        bounds = cxx::std::vector<unsafe *ConstraintExpr>()
            self.tu.assoc_own_bounds(ta, &bounds)
            for var i: usize = 0; i < bounds.size(); ++i {
                var unsafe *c = bounds[i]
                if c->rhs == &null || c->rhs->canonical == &null {
                    continue
                }

                var unsafe *iface = canon_unqual(c->rhs->canonical)
                if iface->is_dependent() {
                    continue
                }

                var ok = true
                if isa<AssocType>(dflt) {
                    ok = false
                    var has = Substitution(self.sc).bound_ifaces(dflt)
                    for var k: usize = 0; k < has.size(); ++k {
                        if self._iface_derives(has[k], iface, 0) {
                            ok = true
                            break
                        }
                    }
                } else if dflt->is_dependent() {
                    continue
                } else {
                    var unsafe *row = self.conforms(dflt, iface)
                    ok = row != &null && row->ok
                }

                if ok {
                    continue
                }

                var nm = self.sc->ctx->get_spelling(ta->name)
                var ds = self.tu.str(dflt)
                var is = self.tu.str(iface)
                var b = self.sc->diag->report(
                    DiagID::SC154E,
                    ta->aliased->range.start,
                    f"the default of associated type '{nm}' is '{ds}', which does not meet its bound '{is}'",
                )

                b.first(ta->aliased->range)
                b.note(c->range.start, "the bound is declared here")->child_first(
                    c->range,
                )

                b.emit()
            }
        }
    }

    /// Interface type \p have is \p want or derives it.
    priv fn _iface_derives(self, have: unsafe *Type, want: unsafe *Type, depth: u32) -> bool {
        if have == &null || want == &null || depth > 32 {
            return false
        }

        if canon_unqual(have) == canon_unqual(want) {
            return true
        }

        var unsafe *d = self._iface_decl(canon_unqual(have))
        if d == &null {
            return false
        }

        for var i: usize = 0; i < d->derives_list.size(); ++i {
            var unsafe *e = d->derives_list.get(i)
            if e == &null || e->base == &null || e->base->canonical == &null {
                continue
            }

            if self._iface_derives(
                canon_unqual(e->base->canonical),
                want,
                depth + 1,
            ) {
                return true
            }
        }

        return false
    }

    /// The type a record declares for itself: `R`, or `R<T, U>` over its
    /// own parameters for a generic one (TypeResolve's `_self_record`).
    /// Null for a record nested in a generic: its witness would be a member
    /// of a template, which a partial specialization cannot key on.
    priv fn _self_type(self, d: unsafe *Decl) -> unsafe *Type {
        var unsafe *rep = NameLookup::representative(d)
        var unsafe *dc0 = d->semantic_dc
        var unsafe *o   = if (dc0 != &null) => (dc0->owner_decl()) else => &null
        for var depth: u32 = 0; o != &null && depth < 32; ++depth {
            if decl_generic_params(o).size() > 0 {
                return &null
            }

            var unsafe *dc = o->semantic_dc
            o = if (dc != &null) => (dc->owner_decl()) else => &null
        }

        var gps  = decl_generic_params(rep)
        var args = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < gps.size(); ++i {
            if gps[i] == &null {
                continue
            }

            args.push_back(
                self.sc->types->generic_param(
                    rep,
                    gps[i]->index,
                    gps[i]->is_pack,
                ),
            )
        }

        return self.sc->types->record(rep, unsafe &args)
    }

    /// A DECLARED conformance of \p x to \p base, written on \p by: its
    /// row, recorded so EmitPlan can admit the witness specialization where
    /// \p by is emitted, with no Kairo instance to reach it -- a C++ host
    /// instantiating a bounded template with X is the use Kairo never sees
    /// (Compiler/Spec/Witnesses.md#emission). A GENERIC conformance (`extend <E> Wrap<E> impl
    /// I`, `class <T> Box impl I`) is one row over \p by's own parameters,
    /// the partial specialization's. A row that does not hold is left
    /// unreported: the impl-only rule is not built, and a host's
    /// instantiation then fails at the concept, as a structural one does.
    priv fn _check_declared(self, by: unsafe *Decl, x: unsafe *Type, base: unsafe *Type) {
        if x == &null || base == &null {
            return
        }

        var unsafe *c     = self._canon(x)
        var unsafe *iface = self._canon(base)
        if c == &null || iface == &null {
            return
        }

        if self._iface_decl(iface) == &null {
            return
        }

        // Dependent on anything but \p by's own parameters (an enclosing
        // generic's), it is not one partial specialization.
        if (c->is_dependent() || iface->is_dependent()) && !isa<RecordType>(c) {
            return
        }

        var unsafe *row = self.conforms(c, iface, by)
        if row == &null || !row->ok {
            return
        }

        self.sc->instances->declare_row(by, row)
    }

    /// Every record instance in \p t, its arguments included (`Vec<Box<M>>`).
    priv fn _check_type(self, t: unsafe *Type, at: SourceRange, depth: u32) {
        if t == &null || depth > 16 {
            return
        }

        var unsafe *c = self._canon(t)
        if c == &null || c->is_dependent() || c->is_instantiation_dependent() {
            return
        }

        match c->kind {
            case TypeKind::PointerType {
                self._check_type(cast<PointerType>(c)->pointee, at, depth + 1)
            } case TypeKind::CXXLValueRefType {
                self._check_type(
                    cast<CXXLValueRefType>(c)->referee,
                    at,
                    depth + 1,
                )
            } case TypeKind::CXXRValueRefType {
                self._check_type(
                    cast<CXXRValueRefType>(c)->referee,
                    at,
                    depth + 1,
                )
            } case TypeKind::NullableType {
                self._check_type(cast<NullableType>(c)->inner, at, depth + 1)
            } case TypeKind::FixedArrayType {
                self._check_type(
                    cast<FixedArrayType>(c)->element,
                    at,
                    depth + 1,
                )
            } case TypeKind::RecordType {
                var unsafe *r = cast<RecordType>(c)
                for var i: usize = 0; i < r->args.size(); ++i {
                    self._check_type(r->args[i], at, depth + 1)
                }

                // `L<i32>::P` uses L<i32>: its bounds hold, and it is homed.
                if r->outer != &null {
                    self._check_type(r->outer, at, depth + 1)
                }

                if r->decl == &null || !decl_is_instance(r->decl) {
                    return
                }

                var unsafe *e = self.sc->instances->entry_of(r->decl)
                if e != &null {
                    self._check_instance(e, at)
                }
            } default {
                return
            }
        }
    }

    /// `I::m(x, ...)` with x of a CONCRETE type: the call is the
    /// instantiation site, of no generic, so it carries its own row
    /// (CallExpr::witness_row). A dependent x is a bound's, and its rows come
    /// with the enclosing instance.
    priv fn _check_qualified(self, c: unsafe *CallExpr) {
        var unsafe *ch = dyn_cast<ChainExpr>(self.tu.strip_parens(c->callee))
        if ch == &null || ch->steps.size() == 0 {
            return
        }

        var unsafe *st = ch->steps.get(ch->steps.size() - 1)
        if st->access_kind != ChainExpr::AccessKind::ColonColon {
            return
        }

        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(st->resolved_decl)
        if f == &null || !f->is_method() || !self._owned_by_interface(f) {
            return
        }

        var ai: i32 = 0
        if c->arg_map.size() > 0 {
            ai = c->arg_map[0]
        }

        if ai < 0 || (ai as usize) >= c->args.size() {
            return
        }

        var unsafe *a = c->args[ai as usize]
        if a == &null || a->type_ == &null {
            return
        }

        var unsafe *x = self._object(a->type_)
        if x == &null {
            return
        }

        if isa<GenericParamType>(x) {
            self._qualified_bound(c, cast<GenericParamType>(x), f)
            return
        }

        if x->is_dependent() || x->is_instantiation_dependent() {
            return
        }

        // The requirement's DECLARING interface at the qualifier's arguments
        // (CallTyping left the qualifier on the call): `Container<i32>::get`
        // checks Box against Container<i32>, and `Sub<i32>::get` against the
        // Container instance Sub derives.
        var unsafe *home               = (f->semantic_dc)->owner_decl()
        var unsafe *idecl              = NameLookup::representative(home)
        var        iface: unsafe *Type = &null
        if c->witness_iface != &null {
            var d = Deduction(self.sc, &null)
            iface = d.declaring_instance(f, c->witness_iface)
        }

        if iface == &null {
            var empty = cxx::std::vector<unsafe *Type>()
            iface = self.sc->types->record(idecl, unsafe &empty)
        }

        var unsafe *row = self.conforms(x, iface)
        if row == &null || !row->ok {
            self._report(c->range, &null, x, iface, row)
            return
        }

        c->witness_row = row
    }

    /// `I<A>::m(c, ...)` with c a bounded parameter: the bound the call goes
    /// through is the one whose `m` is the qualifier's -- with `C impl
    /// Container<i32> + Container<bool>`, `Container<bool>::get(c, 0)` is
    /// the second -- and the call keeps it (CallExpr::witness_iface) for
    /// ExtensionLowering. No such bound is an error here: the first bound
    /// with an `m` would type, and spell a witness the call did not name.
    priv fn _qualified_bound(self,
                             c: unsafe *CallExpr,
                             g: unsafe *GenericParamType,
                             f: unsafe *Declarations::FunctionDecl) {
        if c->witness_iface == &null {
            return
        }

        var        d     = Deduction(self.sc, &null)
        var unsafe *want = d.declaring_instance(f, c->witness_iface)
        if want == &null {
            return
        }

        var it = self.sc->bounds.find(g->owner as usize as u64)
        if it != self.sc->bounds.end() {
            var *_set = &it->second
            for var i: usize = 0; i < _set->impl_constraints.size(); ++i {
                var unsafe *b  = _set->impl_constraints[i]
                var unsafe *id = dyn_cast<NamedIdentExpr>(b->lhs)
                if id == &null {
                    continue
                }

                var unsafe *gp = dyn_cast<Declarations::GenericParamDecl>(
                    id->resolved_decl,
                )

                if gp == &null || gp->index != g->param_index {
                    continue
                }

                if NameLookup::representative(gp->owner) != NameLookup::representative(
                    g->owner,
                ) {
                    continue
                }

                if b->rhs == &null || b->rhs->canonical == &null {
                    continue
                }

                var unsafe *t = canon_unqual(b->rhs->canonical)
                if d.declaring_instance(f, t) == want {
                    c->witness_iface = t
                    return
                }
            }
        }

        var xs = self.tu.str(unsafe (g as unsafe *Type))
        var is = self.tu.str(c->witness_iface)
        var r = self.sc->diag->report(
            DiagID::SC155E,
            c->range.start,
            f"no bound on '{xs}' provides '{is}::{self._req_name(f)}'; bound it 'impl {is}'",
        )

        r.first(c->range)
        r.note(f->range.start, f"'{self._req_name(f)}' is required here")->child_first(
            f->range,
        )

        r.emit()
        c->poison()
    }

    /// The object a value of type \p t is: through a C++ reference, unqualified.
    priv fn _object(self, t: unsafe *Type) -> unsafe *Type {
        var unsafe *c = self._canon(t)
        if c == &null {
            return &null
        }

        if isa<CXXLValueRefType>(c) {
            return canon_unqual(cast<CXXLValueRefType>(c)->referee)
        }

        if isa<CXXRValueRefType>(c) {
            return canon_unqual(cast<CXXRValueRefType>(c)->referee)
        }

        return c
    }

    /// ## the instantiation site

    /// The last range the visitor passed: where a use with no range of its
    /// own (a canonical reached without a written node) is checked when no
    /// written use of the instance follows, instead of not at all (D4).
    priv var _cur_at: SourceRange = SourceRange::invalid()
    /// Roots whose chain already reported the depth limit: one error per
    /// use, however many branches of its chain run past it.
    priv var _too_deep: cxx::std::vector<unsafe *InstanceEntry>
    priv var _indexed:  bool                                    = false
    /// Instances first met with no range, and the range the visitor was
    /// under: checked there if no written use came by the end of the TU.
    priv var _rangeless:    cxx::std::vector<unsafe *InstanceEntry>
    priv var _rangeless_at: cxx::std::vector<SourceRange>

    /// \p e is used at \p site: a root of the discovery fixpoint. Its bounds
    /// are checked here, once for the build -- a non-conforming instance is
    /// reported at its first use, however many times it is named -- and
    /// what its body reaches is walked by discover.
    /// `pick<i32>` read as a value (ExprTyper::generic_fn_value_type typed
    /// it as the instance's fn pointer, by substitution only): the instance
    /// is named here, as a call's is by CallTyping, so its `impl` bounds are
    /// checked at the use and EmitPlan homes it. Unchecked, a bound the
    /// argument does not meet failed only in clang, as an "address of
    /// overloaded function" error. A callee is never typed (CallTyping
    /// binds it untyped), so a node with a fn type here is a value use.
    priv fn _check_fn_value(self, e: unsafe *Expr) {
        if e->type_ == &null
            || e->type_->canonical == &null
            || canon_unqual(e->type_->canonical)->kind != TypeKind::FunctionPointerType {
            return
        }

        var d:  unsafe *Decl                              = &null
        var gl: unsafe *FrozenList<ChainType::GenericArg> = &null
        if e->kind == ExprKind::NamedIdentExpr {
            var unsafe *name = cast<NamedIdentExpr>(e)
            d  = name->resolved_decl
            gl = unsafe &name->generic_args
            if d == &null && name->candidate_cell != &null && name->candidate_cell->size() == 1 {
                d = name->candidate_cell->get(0)
            }
        } else if e->kind == ExprKind::ChainExpr {
            // `m::pick<i32>`: ChainBinding binds the last step, as one decl
            // or as a one-candidate cell.
            var unsafe *ch = cast<ChainExpr>(e)
            if ch->steps.size() == 0 {
                return
            }

            var unsafe *st = ch->steps.get(ch->steps.size() - 1)
            d  = st->resolved_decl
            gl = unsafe &st->generic_args
            if d == &null && st->candidate_cell != &null && st->candidate_cell->size() == 1 {
                d = st->candidate_cell->get(0)
            }

            if d == &null && st->name != &null {
                d = st->name->resolved_decl
            }
        }

        if d == &null || gl == &null || gl->size() == 0 || !isa<Declarations::FunctionDecl>(d) {
            return
        }

        var unsafe *f = cast<Declarations::FunctionDecl>(d)
        if f->is_method() || f->generic_params.size() != gl->size() {
            return
        }

        var args = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < gl->size(); ++i {
            var unsafe *ga = gl->get(i)
            if ga->ty == &null || ga->ty->canonical == &null {
                return
            }

            var unsafe *t = ga->ty->canonical
            if t->is_dependent() || t->is_instantiation_dependent() {
                return // a generic body's `pick<T>`: its own instances bind T.
            }

            args.push_back(t)
        }

        var unsafe *rep = NameLookup::representative(unsafe (f as unsafe *Decl))
        var unsafe *ie = self.sc->instances->instance_for(
            rep,
            unsafe &args,
            self.sc->ctx->fid,
            NameLookup::ctx_of(rep),
        )

        self._check_instance(ie, e->range)
    }

    priv fn _check_instance(self, e: unsafe *InstanceEntry, site: SourceRange) {
        if e == &null {
            return
        }

        if e->depth > 0 {
            self.sc->instances->note_reuse(
                e,
                if (site.start.is_valid()) => (site) else => self._cur_at,
            )

            self._recheck(e, site)
            return
        }

        if !site.start.is_valid() {
            // A written use usually follows (`var b = Box<M>(...)` visits the
            // decl's inferred type before its initializer): wait for it, and
            // fall back to the enclosing range at the end of the TU (run).
            if self._cur_at.start.is_valid() {
                self._rangeless.push_back(e)
                self._rangeless_at.push_back(self._cur_at)
            }

            return
        }

        if !self.sc->instances->mark_live(
            e,
            site,
            &null,
            SourceRange::invalid(),
        ) {
            return
        }

        self._check_bounds(e)
    }

    /// Fill live \p e's rows from its primary's `impl` bounds, reporting at
    /// its use (InstanceEntry::use_at, a reached one's root's) a bound its
    /// argument does not meet. False when one did not: such an instance's
    /// body is not walked (it is marked walked here). The rows found are
    /// unioned into the instance's program-wide list (add_rows, D7).
    priv fn _check_bounds(self, e: unsafe *InstanceEntry) -> bool {
        self._check_selection(e)
        self._check_dynamic_layout(e)
        var rows = cxx::std::vector<unsafe *ConformanceRow>()
        var ok   = self._bound_rows(e, e->use_at, e, unsafe &rows)
        if !ok {
            rows.clear()
            self.sc->instances->set_checked(e)
            self.sc->instances->mark_failed(e)
        }

        self.sc->instances->add_rows(e, unsafe &rows)
        if ok {
            self._check_facts(e)
            self._check_reuse(e)
        }

        return ok
    }

    /// A generic body's transfer of a `T` value (or a `xs...` expansion)
    /// that a later read of the binding follows (FunctionDecl::
    /// move_reuse_site, MoveCheck): the pattern leaves it a copy, since one
    /// C++ template serves every instance and the category is the
    /// instance's. At an instance whose value cannot be copied it is a use
    /// after move (Doc: Ownership) -- reported here, at the instance's use
    /// with its chain (Compiler/Spec/Generics.md#instance-diagnostics), not left to clang as a deleted copy
    /// constructor. A record instance asks each of its methods.
    priv fn _check_reuse(self, e: unsafe *InstanceEntry) {
        if e == &null || e->primary == &null || !e->use_at.start.is_valid() {
            return
        }

        var unsafe *prim = e->primary
        if isa<Declarations::FunctionDecl>(prim) {
            var unsafe *h = self._reuse_home(
                cast<Declarations::FunctionDecl>(prim),
            )

            if h->move_reuse_site.size() == 0 {
                return
            }

            var d = Deduction(self.sc, &null)
            self._bind_instance(&d, e, prim)
            self._reuse_in(e, h, &d, prim)
            return
        }

        if e->decl == &null {
            return
        }

        var        ms  = self._methods_of(prim)
        var unsafe *rt = self.sc->types->record(e->decl, unsafe &e->args)
        for var k: usize = 0; k < ms.size(); ++k {
            if ms[k] == &null {
                continue
            }

            var unsafe *h = self._reuse_home(ms[k])
            if h->move_reuse_site.size() == 0 {
                continue
            }

            var d = Deduction(self.sc, &null)
            if rt != &null {
                d.bind_from_record(rt)
            }

            // A member whose `requires` is false here is dropped from this
            // instance by C++ (its trailing clause, CXXSpell::member_requires),
            // so its body never runs as this instance: a reuse in it is no
            // use after move (vector.k's resize(n, value) on [Mv]).
            if self._requires_false_at(ms[k], unsafe &d) {
                continue
            }

            self._reuse_in(e, h, &d, &null)
        }
    }

    /// True when one of \p f's `requires` value predicates is known false
    /// under \p d; an undecidable one does not count.
    priv fn _requires_false_at(self,
                               f: unsafe *Declarations::FunctionDecl,
                               d: unsafe *Deduction) -> bool {
        return self._requires_blocker(f, d).known
    }

    /// _requires_false_at, and the type whose missing copy (or move) made
    /// the clause false, when one predicate names it.
    priv fn _requires_blocker(self,
                              f: unsafe *Declarations::FunctionDecl,
                              d: unsafe *Deduction) -> PredFalse {
        var out = PredFalse{}
        if f->requires_clause == &null || f->generic_params.size() > 0 {
            return out
        }

        var vps = cxx::std::vector<unsafe *Expr>()
        self._value_preds(f->requires_clause, unsafe &vps)
        for var i: usize = 0; i < vps.size(); ++i {
            out = self._pred_false(vps[i], d, 0)
            if out.known {
                return out
            }
        }

        return out
    }

    /// Value predicate \p p known false under \p d. Beyond _vp: the
    /// transfer facts (_transfer_pred_false), and a disjunction of false
    /// sides, which is how a container's copy guards its recursive case
    /// (`(!__builtin_is_complete<T>()) || __builtin_is_constructible<T,
    /// const T>()`, vector.k): at a concrete, complete T the first side is
    /// false and the second decides.
    priv fn _pred_false(self, p: unsafe *Expr, d: unsafe *Deduction, depth: u32) -> PredFalse {
        var out = PredFalse{}
        if p == &null || depth > 64 {
            return out
        }

        var v = self._vp(p, d, 0)
        if v.known && v.v == 0 {
            out.known = true
            return out
        }

        var unsafe *x = self.tu.strip_parens(p)
        var unsafe *t = self._transfer_pred_false(x, d)
        if t != &null {
            out.known   = true
            out.blocker = t
            return out
        }

        var unsafe *b = dyn_cast<BinaryOperatorExpr>(x)
        if b != &null
            && (b->op_token.kind == TokenKind::OpPipePipe || b->op_token.kind == TokenKind::KwOr) {
            var l = self._pred_false(b->lhs, d, depth + 1)
            if !l.known {
                return out
            }

            var r = self._pred_false(b->rhs, d, depth + 1)
            if r.known && r.blocker == &null {
                r.blocker = l.blocker
            }

            return r
        }

        var unsafe *u = dyn_cast<UnaryOperatorExpr>(x)
        if u != &null
            && (u->op_token.kind == TokenKind::OpExclaim || u->op_token.kind == TokenKind::KwNot)
            && self._complete_pred_true(u->operand, d) {
            out.known = true
        }

        return out
    }

    /// `__builtin_is_complete<X>()` known true under \p d: X is a concrete
    /// Kairo record. One is complete wherever an instance's member is judged
    /// (a body, not the record's own definition, the case the predicate
    /// guards); an imported record may be only declared, so it stays
    /// unknown.
    priv fn _complete_pred_true(self, p: unsafe *Expr, d: unsafe *Deduction) -> bool {
        var unsafe *c = dyn_cast<CallExpr>(self.tu.strip_parens(p))
        if c == &null || c->args.size() != 0 {
            return false
        }

        var unsafe *callee = self._callee_of(c)
        if callee == &null || self.tu.decl_name(callee) != "__builtin_is_complete" {
            return false
        }

        var unsafe *ni = dyn_cast<NamedIdentExpr>(
            self.tu.strip_parens(c->callee),
        )

        if ni == &null || ni->generic_args.size() != 1 {
            return false
        }

        var unsafe *t = self._subst(ni->generic_args.get(0)->ty, d)
        if t == &null || t->is_dependent() || t->is_instantiation_dependent() {
            return false
        }

        var unsafe *rd = self.tu.record_decl(canon_unqual(t))
        return rd != &null && !decl_is_imported(NameLookup::representative(rd))
    }

    /// The `@copy` constructor record type \p rt's declaration declares,
    /// when its `requires` is known false at \p rt, and the type argument
    /// whose copy it needed: C++ drops that constructor from the instance
    /// (CXXSpell::member_requires), so the instance has no copy although
    /// ClassLifecycle, reading the declaration, calls it COPY (`[Mv]`).
    /// MoveCheck asks at each copy of an lvalue.
    pub fn dropped_copy(self, rt: unsafe *Type) -> DroppedCopy {
        var        out = DroppedCopy{}
        var unsafe *c  = canon_unqual(rt)
        if c == &null
            || !isa<RecordType>(c)
            || c->is_dependent()
            || c->is_instantiation_dependent() {
            return out
        }

        var unsafe *rd = self.tu.record_decl(c)
        if rd == &null || decl_is_imported(NameLookup::representative(rd)) {
            return out
        }

        var ms = self._methods_of(
            NameLookup::representative(self.tu.pattern_of(rd)),
        )

        for var k: usize = 0; k < ms.size(); ++k {
            var unsafe *m = ms[k]
            if m == &null
                || m->transfer != Declarations::TransferKind::Copy
                || m->requires_clause == &null
                || m->body_kind == Declarations::FnBodyKind::Delete {
                continue
            }

            var d = Deduction(self.sc, &null)
            d.bind_from_record(c)
            var why = self._requires_blocker(m, unsafe &d)
            if why.known {
                out.ctor    = m
                out.element = why.blocker
                return out
            }
        }

        return out
    }

    /// `__builtin_is_constructible<X, const X>()` (or `<X, X>`) known false
    /// under \p d: X cannot be copied (or neither copied nor moved). The
    /// copy/move form is what a container member's `requires` spells, and
    /// the one the move check has to agree with C++ on.
    /// \return X then, else null.
    priv fn _transfer_pred_false(self, p: unsafe *Expr, d: unsafe *Deduction) -> unsafe *Type {
        var unsafe *c = dyn_cast<CallExpr>(self.tu.strip_parens(p))
        if c == &null || c->args.size() != 0 {
            return &null
        }

        var unsafe *callee = self._callee_of(c)
        if callee == &null || self.tu.decl_name(callee) != "__builtin_is_constructible" {
            return &null
        }

        var unsafe *ni = dyn_cast<NamedIdentExpr>(
            self.tu.strip_parens(c->callee),
        )

        if ni == &null || ni->generic_args.size() != 2 {
            return &null
        }

        var unsafe *a0 = ni->generic_args.get(0)->ty
        var unsafe *a1 = ni->generic_args.get(1)->ty
        var unsafe *t0 = self._subst(a0, d)
        var unsafe *t1 = self._subst(a1, d)
        if t0 == &null || t1 == &null || canon_unqual(t0) != canon_unqual(t1) {
            return &null
        }

        var f = lifecycle_of(self.sc)->facts_of_type_concrete(
            canon_unqual(t0),
            "ConformanceChecking",
        )

        if f.copyable != LifecycleTri::No {
            // X's declaration says COPY, but its own instance may have lost
            // its copy the same way (`[[Mv]]`): ask it in turn. The type
            // arguments only get smaller, so this ends.
            if a1->is_const() && self.dropped_copy(t0).ctor != &null {
                return canon_unqual(t0)
            }

            return &null
        }

        if a1->is_const() || f.movable == LifecycleTri::No {
            return canon_unqual(t0)
        }

        return &null
    }

    priv fn _reuse_home(self,
                        f: unsafe *Declarations::FunctionDecl) -> unsafe *Declarations::FunctionDecl {
        var unsafe *d = f->definition()
        return if (d != &null) => (d) else => f
    }

    /// \p h's demoted transfers at instance \p e (\p d its bindings;
    /// \p prim the generic function, whose pack's elements are \p e's
    /// trailing arguments, or null for a record's method).
    priv fn _reuse_in(self,
                      e:    unsafe *InstanceEntry,
                      h:    unsafe *Declarations::FunctionDecl,
                      d:    *Deduction,
                      prim: unsafe *Decl) {
        for var i: usize = 0; i < h->move_reuse_site.size() && i < h->move_reuse_read.size(); ++i {
            var unsafe *site = h->move_reuse_site[i]
            var unsafe *read = h->move_reuse_read[i]
            if site == &null || read == &null {
                continue
            }

            var bad: unsafe *Type = &null
            if isa<PackExpansionExpr>(site) {
                bad = self._reuse_pack_element(
                    e,
                    cast<PackExpansionExpr>(site),
                    prim,
                )
            } else if site->type_ != &null {
                var unsafe *t = d->substitute(canon_unqual(site->type_))
                if t != &null && !t->is_dependent() && !t->is_instantiation_dependent() {
                    if lifecycle_of(self.sc)->facts_of_type(t).copyable == LifecycleTri::No {
                        bad = canon_unqual(t)
                    }
                }
            }

            if bad == &null {
                continue
            }

            var nm   = self.sc->ctx->get_spelling(read->range)
            var ts   = self.tu.str(bad)
            var inst = self._inst_name(e)
            var b = self.sc->diag->report(
                DiagID::SC052E,
                e->use_at.start,
                f"'{nm}' is used after being moved in '{inst}': '{ts}' cannot be copied, so the transfer moves it",
            )

            b.first(e->use_at, f"'{inst}' is instantiated here")
            b.note(site->range.start, f"'{nm}' was moved here, as a '{ts}'")->child_first(
                site->range,
            )

            b.note(read->range.start, "and used again here")->child_first(
                read->range,
            )

            self.chain_notes(unsafe &b, e)
            b.emit()
        }
    }

    /// The first element of the pack \p x expands that cannot be copied
    /// at instance \p e, or null. Only a pack parameter of \p prim's own
    /// (`...xs: T`, its one trailing variadic): its elements are \p e's
    /// arguments from the type pack's position on (instance args are flat).
    priv fn _reuse_pack_element(self,
                                e:    unsafe *InstanceEntry,
                                x:    unsafe *PackExpansionExpr,
                                prim: unsafe *Decl) -> unsafe *Type {
        if prim == &null {
            return &null
        }

        var unsafe *opd = self.tu.strip_parens(x->operand)
        if opd == &null || !isa<NamedIdentExpr>(opd) {
            return &null
        }

        var unsafe *pd = dyn_cast<Declarations::ParamDecl>(
            cast<NamedIdentExpr>(opd)->resolved_decl,
        )

        if pd == &null || !pd->is_pack {
            return &null
        }

        var gps = decl_generic_params(prim)
        var k   = usize::MAX
        for var i: usize = 0; i < gps.size(); ++i {
            if gps[i] != &null && gps[i]->is_pack {
                k = i
            }
        }

        if k == usize::MAX {
            return &null
        }

        var unsafe *xd = decl_extension_of(prim)
        if xd != &null {
            k += decl_generic_params(unsafe (xd as unsafe *Decl)).size()
        }

        for var j: usize = k; j < e->args.size(); ++j {
            var unsafe *a = e->args[j]
            if a == &null || a->is_dependent() {
                continue
            }

            if lifecycle_of(self.sc)->facts_of_type(a).copyable == LifecycleTri::No {
                return canon_unqual(a)
            }
        }

        return &null
    }

    /// Instances another TU (or an earlier use here) made live, already
    /// checked once for the build, that THIS TU uses directly: their bounds
    /// asked again against what this TU can see (Compiler/Spec/Interfaces.md#program-wide-rows-per-tu-visibility, the per-TU
    /// filter), reported at this use with no chain -- it is a root here.
    /// Once per instance per TU. Not for an instance that failed where it
    /// became live (reported there, D6), and not for a reached one: a
    /// reached instance's rows are implied by its root's bounds, which its
    /// root's own use checks here.
    priv var _rechecked: cxx::std::vector<unsafe *InstanceEntry>
    priv fn _recheck(self, e: unsafe *InstanceEntry, site: SourceRange) {
        if e->failed {
            return
        }

        var at = site
        if !at.start.is_valid() {
            at = self._cur_at
        }

        if !at.start.is_valid() {
            return
        }

        for var i: usize = 0; i < self._rechecked.size(); ++i {
            if self._rechecked[i] == e {
                return
            }
        }

        self._rechecked.push_back(e)
        var rows = cxx::std::vector<unsafe *ConformanceRow>()
        if self._bound_rows(e, at, &null, unsafe &rows) {
            self.sc->instances->add_rows(e, unsafe &rows)
        }
    }

    /// \p e's rows from its primary's `impl` bounds as this TU sees them,
    /// appended to \p rows; a bound not met is reported at \p at, with
    /// \p chain's instantiation chain when non-null. False when one was not.
    priv fn _bound_rows(self,
                        e:     unsafe *InstanceEntry,
                        at:    SourceRange,
                        chain: unsafe *InstanceEntry,
                        rows:  unsafe *cxx::std::vector<unsafe *ConformanceRow>) -> bool {
        var unsafe *prim = e->primary
        var        ok    = true
        if prim != &null {
            var unsafe *req   = decl_requires_clause(prim)
            var        bounds = cxx::std::vector<unsafe *ConstraintExpr>()
            self._impl_bounds(req, unsafe &bounds)
            for var i: usize = 0; i < bounds.size(); ++i {
                var unsafe *b  = bounds[i]
                var unsafe *gp = self._param_named(b, prim)
                if gp == &null || gp->is_pack {
                    continue
                }

                var unsafe *x     = self._arg_of(e, prim, gp)
                var unsafe *iface = self._bound_iface(b, prim, e)
                if x == &null || iface == &null {
                    continue
                }

                var unsafe *row = self.conforms(x, iface)
                if row == &null || !row->ok {
                    self._report(at, b, x, iface, row, chain)
                    ok = false
                    continue
                }

                if !self._push_closure(row, x, &*rows, at, b) {
                    ok = false
                }
            }

            // `X derives B`: the argument is B or reaches it. Checked
            // because the bound is what makes a CRTP
            // base's `&self as *X` a static_cast (CastTyping 3b), and a
            // class naming `Mixin<Other>` would otherwise compile to a cast
            // clang rejects inside the base.
            var ds = cxx::std::vector<unsafe *ConstraintExpr>()
            self._derives_bounds(req, unsafe &ds)
            for var i: usize = 0; i < ds.size(); ++i {
                var unsafe *b  = ds[i]
                var unsafe *gp = self._param_named(b, prim)
                if gp == &null || gp->is_pack {
                    continue
                }

                var unsafe *x    = self._arg_of(e, prim, gp)
                var unsafe *base = self._bound_iface(b, prim, e)
                if x == &null || base == &null || x->is_dependent() || base->is_dependent() {
                    continue
                }

                if !isa<RecordType>(canon_unqual(base)) {
                    continue
                }

                if Substitution(self.sc).derives_from(x, base) {
                    continue
                }

                var xs = self.tu.str(x)
                var bs = self.tu.str(base)
                var bd = self.sc->diag->report(
                    DiagID::SC156E,
                    at.start,
                    f"'{xs}' does not derive '{bs}'",
                )

                bd.first(at)
                bd.note(b->range.start, "required by this bound")->child_first(
                    b->range,
                )

                if chain != &null {
                    self.chain_notes(unsafe &bd, chain)
                }

                bd.emit()
                ok = false
            }

            if !self._kind_bounds_ok(e, prim, at, chain) {
                ok = false
            }
        }

        return ok
    }

    /// The kind bounds `T: class` / `struct` / `enum` / `union`
    /// (generics.mdx: they restrict T to that category of declaration) at
    /// instance \p e. Without this check, `fn <T: class>
    /// f(x: T)` would accept `f(1)`. A dependent argument is the enclosing generic's
    /// to meet; `: type` (Duck) and no bound restrict nothing. SC292E.
    priv fn _kind_bounds_ok(self,
                            e:     unsafe *InstanceEntry,
                            prim:  unsafe *Decl,
                            at:    SourceRange,
                            chain: unsafe *InstanceEntry) -> bool {
        var ok  = true
        var gps = decl_generic_params(prim)
        for var i: usize = 0; i < gps.size(); ++i {
            var unsafe *gp = gps[i]
            if gp == &null || gp->is_pack {
                continue
            }

            var kw = Self::_kind_keyword(gp->kind_bound)
            if kw.size() == 0 {
                continue
            }

            var unsafe *x = self._arg_of(e, prim, gp)
            if x == &null || x->is_dependent() || x->is_instantiation_dependent() {
                continue
            }

            if Self::_kind_of_type(x) == gp->kind_bound {
                continue
            }

            var xs = self.tu.str(x)
            var gn = self.sc->ctx->get_spelling(gp->name)
            var ar = if (kw == "enum") => ("an") else => "a"
            var bd = self.sc->diag->report(
                DiagID::SC292E,
                at.start,
                f"'{xs}' is not {ar} {kw}, so it cannot be '{gn}'",
            )

            bd.first(at)
            var nat = if (gp->kind_bound_range.is_valid()) => (gp->kind_bound_range)
                      else => gp->range
            bd.note(
                DiagCode(DiagID::SC292N),
                nat.start,
                f"'{gn}' is bounded '{gn}: {kw}' here",
            )->child_first(nat)
            if chain != &null {
                self.chain_notes(unsafe &bd, chain)
            }

            bd.emit()
            ok = false
        }

        return ok
    }

    /// The keyword a restricting kind bound is written with, or "".
    priv static fn _kind_keyword(k: Declarations::GenericParamKindBound) -> string {
        match k {
            case Declarations::GenericParamKindBound::Class {
                return "class"
            } case Declarations::GenericParamKindBound::Struct {
                return "struct"
            } case Declarations::GenericParamKindBound::Enum {
                return "enum"
            } case Declarations::GenericParamKindBound::Union {
                return "union"
            } default {
                return ""
            }
        }

        return ""
    }

    /// The kind bound canonical \p t meets: the declaration behind a record
    /// type, Any for every other type (a builtin, a pointer, `T?`, ...).
    priv static fn _kind_of_type(t: unsafe *Type) -> Declarations::GenericParamKindBound {
        var unsafe *c = canon_unqual(t)
        if c == &null || !isa<RecordType>(c) {
            return Declarations::GenericParamKindBound::Any
        }

        var unsafe *d = cast<RecordType>(c)->decl
        if d == &null {
            return Declarations::GenericParamKindBound::Any
        }

        if isa<Declarations::ClassDecl>(d) {
            return Declarations::GenericParamKindBound::Class
        }

        if isa<Declarations::StructDecl>(d) {
            return Declarations::GenericParamKindBound::Struct
        }

        if isa<Declarations::EnumDecl>(d) {
            return Declarations::GenericParamKindBound::Enum
        }

        if isa<Declarations::UnionDecl>(d) {
            return Declarations::GenericParamKindBound::Union
        }

        return Declarations::GenericParamKindBound::Any
    }

    /// Every `derives` conjunct of \p e, in clause order (_impl_bounds' other
    /// half).
    priv fn _derives_bounds(self,
                            e:   unsafe *Expr,
                            out: unsafe *cxx::std::vector<unsafe *ConstraintExpr>) {
        if e == &null {
            return
        }

        if e->kind == ExprKind::BinaryOperatorExpr {
            var unsafe *b = cast<BinaryOperatorExpr>(e)
            if b->op_token.kind == TokenKind::OpAmpAmp || b->op_token.kind == TokenKind::KwAnd {
                self._derives_bounds(b->lhs, out)
                self._derives_bounds(b->rhs, out)
                return
            }
        }

        if e->kind != ExprKind::ConstraintExpr {
            return
        }

        var unsafe *c = cast<ConstraintExpr>(e)
        if c->is_derives() {
            out->push_back(c)
        }
    }

    /// Live record instance \p e's lifecycle (Compiler/Spec/Ownership.md#instances-of-generic-records): a rule its
    /// generic class's declaration could not decide (an Unknown fact) that
    /// the instance's own facts fail, reported at its use with its chain
    /// (D6). Once per build, with the bounds; a failure the declaration
    /// shows is the declaration's, never repeated here (instance_failures).
    /// The partial selection of a live instance, at its use, unless T
    /// already reported it at a written type (TypeResolve): two partials
    /// that tie, or one whose `requires` clause the registry could not
    /// decide at these arguments (Compiler/Spec/Generics.md#where-groups-on-generic-functions). An expression head
    /// (`Fit<Big> { ... }`) mints its instance where T never sees it.
    priv fn _check_selection(self, e: unsafe *InstanceEntry) {
        if e == &null || !e->use_at.start.is_valid() {
            return
        }

        if e->ambiguous_a != &null && self.sc->instances->claim(e, InstanceLatch::Ambiguity) {
            var b = self.sc->diag->report(
                DiagID::SC157E,
                e->use_at.start,
                f"ambiguous partial specializations of '{self.tu.decl_name(e->primary)}' for these arguments",
            )

            b.first(e->use_at)
            b.note(
                DiagCode(DiagID::SC157N),
                e->ambiguous_a->range.start,
                "matches this partial specialization",
            )

            b.note(
                DiagCode(DiagID::SC157N),
                e->ambiguous_b->range.start,
                "and this one, and neither is more specialized than the other",
            )

            self.chain_notes(unsafe &b, e)
            b.emit()
        }

        if e->undecided != &null && self.sc->instances->claim(e, InstanceLatch::Undecided) {
            var b = self.sc->diag->report(
                DiagID::SC158E,
                e->use_at.start,
                f"cannot decide whether a partial specialization of '{self.tu.decl_name(e->primary)}' applies to these arguments",
            )

            b.first(e->use_at)
            b.note(
                DiagCode(DiagID::SC158N),
                e->undecided->range.start,
                "its 'requires' clause is decided at compile time only from literals and the 'sizeof' / 'alignof' of builtins, pointers and arrays of them",
            )

            self.chain_notes(unsafe &b, e)
            b.emit()
        }
    }

    /// `__builtin_dynamic_size<T>` / `_align<T>` at a T that is polymorphic
    /// with no virtual destructor: what p points at may be a larger derived
    /// class, and nothing at run time says which (only a virtual destructor
    /// gives T the hidden `__kairo_layout()`, InterfaceEmitter). Deleting
    /// through such a base is already undefined. Reported at the use, with
    /// its chain -- usually `destroy<T>`'s caller. A fact still Unknown is
    /// left to the intrinsic's C++ static_assert.
    priv fn _check_dynamic_layout(self, e: unsafe *InstanceEntry) {
        if e == &null || e->primary == &null || !isa<Declarations::FunctionDecl>(e->primary) {
            return
        }

        if !self._is_lang(e->primary, WellKnownType::DynamicSize)
            && !self._is_lang(e->primary, WellKnownType::DynamicAlign) {
            return
        }

        if !e->use_at.start.is_valid() || e->args.size() != 1 {
            return
        }

        var unsafe *t = self._canon(e->args[0])
        if t == &null
            || !isa<RecordType>(t)
            || t->is_dependent()
            || t->is_instantiation_dependent() {
            return
        }

        var f = lifecycle_of(self.sc)->facts_of_type_concrete(
            t,
            "ConformanceChecking",
        )

        if f.polymorphic != LifecycleTri::Yes || f.virtual_dtor != LifecycleTri::No {
            return
        }

        var ts = self.tu.str(t)
        var b = self.sc->diag->report(
            DiagID::SC159E,
            e->use_at.start,
            f"'{self._inst_name(e)}' needs the layout of what a '*{ts}' points at, but '{ts}' is polymorphic and has no virtual destructor",
        )

        b.first(e->use_at)
        var unsafe *rd = cast<RecordType>(t)->decl
        if rd != &null {
            b.note(
                DiagCode(DiagID::SC159N),
                rd->range.start,
                f"declare 'virtual fn op finally(self)' in '{ts}'",
            )->child_first(rd->range)
        }

        self.chain_notes(unsafe &b, e)
        b.emit()
    }

    priv fn _check_facts(self, e: unsafe *InstanceEntry) {
        if e == &null || e->primary == &null || isa<Declarations::FunctionDecl>(e->primary) {
            return
        }

        if !e->use_at.start.is_valid() {
            return
        }

        var fails = cxx::std::vector<LifecycleFailure>()
        lifecycle_of(self.sc)->instance_failures(e, unsafe &fails)
        for var i: usize = 0; i < fails.size(); ++i {
            var *x = &fails[i]
            var b  = self.sc->diag->report(x->id, e->use_at.start, x->msg)
            b.first(e->use_at, f"'{self._inst_name(e)}' is instantiated here")
            for var k: usize = 0; k < x->note_ids.size(); ++k {
                b.note(
                    DiagCode(x->note_ids[k]),
                    x->note_at[k].start,
                    x->note_msg[k],
                )->child_first(x->note_at[k])
            }

            self.chain_notes(unsafe &b, e)
            b.emit()
        }
    }

    /// THE discovery fixpoint (Compiler/Spec/Generics.md#m1-enumeration): walk every live instance's reach,
    /// a batch at a time in worklist (mint) order, until a walk makes nothing
    /// new live. Run at the end of each TU's checks, and again by M1, where
    /// it finds the worklist empty unless something after the checks made an
    /// instance live. A chain longer than --cmax-generic-depth is an error
    /// (_too_deep), never a silent stop.
    fn discover(self) {
        var unsafe *reg = self.sc->instances
        if reg == &null {
            return
        }

        var batch = cxx::std::vector<unsafe *InstanceEntry>()
        reg->drain(unsafe &batch)
        // M1's pass is a fresh one: a row's member lookup needs the
        // extension index run() builds.
        if batch.size() > 0 && !self._indexed {
            self.ml.index_extensions()
            self._indexed = true
        }

        while batch.size() > 0 {
            for var i: usize = 0; i < batch.size(); ++i {
                reg->set_checked(batch[i])
                self._walk(batch[i])
            }

            batch.clear()
            reg->drain(unsafe &batch)
        }
    }

    /// Instance \p e's argument for \p gp, a parameter of \p prim or of its
    /// extension: instance arguments run in CXXSpell::template_params order,
    /// an extension's first.
    priv fn _arg_of(self,
                    e:    unsafe *InstanceEntry,
                    prim: unsafe *Decl,
                    gp:   unsafe *Declarations::GenericParamDecl) -> unsafe *Type {
        var        off: usize = 0
        var unsafe *x         = decl_extension_of(prim)
        if x != &null {
            var eps = decl_generic_params(unsafe (x as unsafe *Decl))
            for var i: usize = 0; i < eps.size(); ++i {
                if eps[i] == gp {
                    off = i
                    return if (off < e->args.size()) => (canon_unqual(e->args[off])) else => &null
                }
            }

            off = eps.size()
        }

        var k = off + (gp->index as usize)
        return if (k < e->args.size()) => (canon_unqual(e->args[k])) else => &null
    }

    /// Walk live \p e's primary's body (a record's: its methods, and its
    /// fields' types) for the dependent uses that become instances
    /// under \p e's arguments. Each is minted, linked (InstanceEntry::reached:
    /// every plan holding \p e homes or `extern`s it, and admits its rows,
    /// Compiler/Spec/Witnesses.md#emission) and made live one hop below \p e, which checks its
    /// bounds; its own reach is the worklist's next batch. The cycle state
    /// is the entry's (`checked`), never the decl's: every function instance
    /// shares its primary's decl.
    priv fn _walk(self, e: unsafe *InstanceEntry) {
        var unsafe *prim = e->primary
        if prim == &null {
            return
        }

        var uses = _NestedUses()
        if isa<Declarations::FunctionDecl>(prim) {
            uses.dispatch_decl(prim)
        } else {
            var ms = self._methods_of(prim)
            for var i: usize = 0; i < ms.size(); ++i {
                if ms[i] != &null {
                    uses.dispatch_decl(unsafe (ms[i] as unsafe *Decl))
                }
            }

            // The fields' types are instantiated with the record (C++ checks a
            // constrained template's bounds even where it is only named, as
            // behind a pointer), and a field is no method's use.
            var fs = self._fields_of(prim)
            for var i: usize = 0; i < fs.size(); ++i {
                var unsafe *f = fs[i]
                if f == &null || f->type_ == &null {
                    continue
                }

                var unsafe *ft = self._canon(f->type_)
                if ft == &null || !ft->is_dependent() {
                    continue
                }

                uses.types.push_back(f->type_)
                uses.type_at.push_back(f->range)
            }
        }

        if uses.calls.size() == 0 && uses.types.size() == 0 {
            return
        }

        var d = Deduction(self.sc, &null)
        self._bind_instance(&d, e, prim)
        for var i: usize = 0; i < uses.calls.size(); ++i {
            var unsafe *c      = uses.calls[i]
            var unsafe *callee = self._callee_of(c)
            if callee == &null || self._owned_by_interface(callee) {
                continue
            }

            var args  = cxx::std::vector<unsafe *Type>()
            var whole = true
            for var k: usize = 0; k < c->dep_args.size(); ++k {
                var unsafe *s = d.substitute(c->dep_args[k])
                if s == &null || s->is_dependent() || s->is_instantiation_dependent() {
                    whole = false
                    break
                }

                args.push_back(canon_unqual(s))
            }

            if !whole { // a parameter of an inner generic: that one's instances reach it.
                continue
            }

            var unsafe *rep = NameLookup::representative(callee)
            if e->depth >= self._depth_limit() {
                var unsafe *have = self.sc->instances->find(rep, unsafe &args)
                if have == &null || have->depth == 0 {
                    self._too_deep_at(
                        e,
                        self._spell(rep, unsafe &args),
                        c->range,
                    )

                    return
                }
            }

            var unsafe *ne = self.sc->instances->instance_for(
                rep,
                unsafe &args,
                self.sc->ctx->fid,
                NameLookup::ctx_of(rep),
            )

            if ne == &null {
                continue
            }

            self.sc->instances->add_reach(e, ne)
            // Its failure is reported at the root use, the hop notes saying
            // which body asked for it (chain_notes).
            if self.sc->instances->mark_live(
                ne,
                SourceRange::invalid(),
                e,
                c->range,
            ) {
                self._check_bounds(ne)
            }
        }

        for var i: usize = 0; i < uses.types.size(); ++i {
            var unsafe *s = d.substitute(self._canon(uses.types[i]))
            if s == &null || s->is_dependent() {
                continue
            }

            var at = uses.type_at[i]
            if !at.start.is_valid() {
                at = e->use_at
            }

            if !self._take_type(e, s, at, 0) {
                return
            }
        }
    }

    /// Every record instance in substituted type \p t, as _check_type finds
    /// them, each linked as reached by \p outer and made live below it at
    /// \p at. False when the chain ran past the depth limit (reported).
    priv fn _take_type(self,
                       outer: unsafe *InstanceEntry,
                       t:     unsafe *Type,
                       at:    SourceRange,
                       depth: u32) -> bool {
        var unsafe *c = self._canon(t)
        if c == &null || depth > 16 {
            return true
        }

        match c->kind {
            case TypeKind::PointerType {
                return self._take_type(
                    outer,
                    cast<PointerType>(c)->pointee,
                    at,
                    depth + 1,
                )
            } case TypeKind::CXXLValueRefType {
                return self._take_type(
                    outer,
                    cast<CXXLValueRefType>(c)->referee,
                    at,
                    depth + 1,
                )
            } case TypeKind::CXXRValueRefType {
                return self._take_type(
                    outer,
                    cast<CXXRValueRefType>(c)->referee,
                    at,
                    depth + 1,
                )
            } case TypeKind::NullableType {
                return self._take_type(
                    outer,
                    cast<NullableType>(c)->inner,
                    at,
                    depth + 1,
                )
            } case TypeKind::FixedArrayType {
                return self._take_type(
                    outer,
                    cast<FixedArrayType>(c)->element,
                    at,
                    depth + 1,
                )
            } case TypeKind::RecordType {
                var unsafe *r = cast<RecordType>(c)
                for var i: usize = 0; i < r->args.size(); ++i {
                    if !self._take_type(outer, r->args[i], at, depth + 1) {
                        return false
                    }
                }

                if r->outer != &null && !self._take_type(outer, r->outer, at, depth + 1) {
                    return false
                }

                if r->decl == &null || !decl_is_instance(r->decl) {
                    return true
                }

                var unsafe *ne = self.sc->instances->entry_of(r->decl)
                if ne == &null {
                    return true
                }

                self.sc->instances->add_reach(outer, ne)
                if ne->depth > 0 {
                    return true
                }

                if outer->depth >= self._depth_limit() {
                    self._too_deep_at(outer, self.tu.str(c), at)
                    return false
                }

                if self.sc->instances->mark_live(
                    ne,
                    SourceRange::invalid(),
                    outer,
                    at,
                ) {
                    self._check_bounds(ne)
                }

                return true
            } default {
                return true
            }
        }
    }

    priv fn _depth_limit(self) -> u32 {
        var lim = self.sc->opts.max_generic_depth
        if lim < 1 {
            lim = 1
        }

        return lim as u32
    }

    /// Live \p e, at the depth limit, needs \p next at \p at in its body: the
    /// chain is too long (D4). One error per root, at the root's use, naming
    /// the chain's first three and last three instances.
    priv fn _too_deep_at(self, e: unsafe *InstanceEntry, const next: string, at: SourceRange) {
        var        chain = cxx::std::vector<unsafe *InstanceEntry>()
        var unsafe *r    = e
        while r != &null {
            chain.push_back(r)
            r = r->via
        }

        var unsafe *root = chain[chain.size() - 1]
        for var i: usize = 0; i < self._too_deep.size(); ++i {
            if self._too_deep[i] == root {
                return
            }
        }

        self._too_deep.push_back(root)
        var names = cxx::std::vector<string>()
        for var i: usize = chain.size(); i > 0; --i {
            names.push_back(self._inst_name(chain[i - 1]))
        }

        names.push_back(next)
        var n     = names.size()
        var shown = ""
        for var i: usize = 0; i < n; ++i {
            if n > 6 && i >= 3 && i + 3 < n {
                if i == 3 {
                    shown += " -> ..."
                }

                continue
            }

            if i > 0 {
                shown += " -> "
            }

            shown += "'" + names[i] + "'"
        }

        var lim = self._depth_limit()
        var b = self.sc->diag->report(
            DiagID::SC160E,
            e->use_at.start,
            f"instantiation depth exceeds {lim}: {shown}",
        )

        b.first(e->use_at, "the chain starts here")
        if at.start.is_valid() {
            b.note(
                at.start,
                f"'{next}' is required here, instantiation {lim + 1} of the chain",
            )->child_first(at)
        }

        b.note("the limit is set by --cmax-generic-depth")
        b.emit()
    }

    /// The instantiation chain of reached instance \p e, on \p b, an error
    /// reported at its root's use (Compiler/Spec/Generics.md#instance-diagnostics): one note per hop, innermost
    /// first, "in instantiation of 'X<A>' required here" at the use in the
    /// body that needed X<A>. Past N = --cmax-generic-backtrace hops
    /// (default 5: the first 3 and the last 2) the first ceil(N/2) and the
    /// last floor(N/2) are shown, with a note counting the rest. Each hop is one instance (the chain is the `via`
    /// links, acyclic), and an instance's failure is reported once, at the
    /// first use that needed it, so a second use of a failing instance adds
    /// nothing. Nothing for a root (\p e used directly). Public: a fact that
    /// fails for an instance (a lifecycle failure) reports at `use_at` with this.
    fn chain_notes(self, b: unsafe *DiagBuilder, e: unsafe *InstanceEntry) {
        var        hops = cxx::std::vector<unsafe *InstanceEntry>()
        var unsafe *h   = e
        while h != &null && h->via != &null {
            hops.push_back(h)
            h = h->via
        }

        var n = hops.size()
        if n == 0 {
            return
        }

        var cap = n
        if self.sc->opts.max_generic_backtrace > 0 {
            cap = (self.sc->opts.max_generic_backtrace as usize)
        }

        var head        = n
        var tail: usize = 0
        if n > cap {
            head = (cap + 1) / 2
            tail = cap / 2
        }

        for var i: usize = 0; i < n; ++i {
            if i >= head && i + tail < n {
                if i == head {
                    var more = n - head - tail
                    b->note(
                        f"{more} more instantiations in the chain; --cmax-generic-backtrace=0 shows them all",
                    )
                }

                continue
            }

            var unsafe *hp = hops[i]
            if !hp->via_at.start.is_valid() {
                continue
            }

            b->note(
                hp->via_at.start,
                f"in instantiation of '{self._inst_name(hp)}' required here",
            )->child_first(hp->via_at)
        }
    }

    /// \p e as the user reads it: `Wrap<Metric>`, `inner<Wrap<Metric>>`.
    priv fn _inst_name(self, e: unsafe *InstanceEntry) -> string {
        if e->decl != &null && !isa<Declarations::FunctionDecl>(e->primary) {
            var unsafe *t = self.sc->types->record(e->decl, unsafe &e->args)
            if t != &null {
                return self.tu.str(t)
            }
        }

        return self._spell(e->primary, unsafe &e->args)
    }

    priv fn _spell(self,
                   prim: unsafe *Decl,
                   args: unsafe *cxx::std::vector<unsafe *Type>) -> string {
        var s = self.tu.decl_name(prim)
        s += "<"
        for var i: usize = 0; i < args->size(); ++i {
            if i > 0 {
                s += ", "
            }

            s += self.tu.str((*args)[i])
        }

        s += ">"
        return s
    }

    /// \p e's arguments bound to \p prim's parameters (an extension
    /// member's extension's first; a record method's body sees its record's).
    priv fn _bind_instance(self, d: *Deduction, e: unsafe *InstanceEntry, prim: unsafe *Decl) {
        var        k: usize = 0
        var unsafe *x       = decl_extension_of(prim)
        if x != &null {
            var        eps = decl_generic_params(x)
            var unsafe *xr = NameLookup::representative(x)
            for var i: usize = 0; i < eps.size() && k < e->args.size(); ++i {
                if eps[i] != &null {
                    d->bind(xr, eps[i]->index, e->args[k])
                }

                k += 1
            }
        }

        var        gps = decl_generic_params(prim)
        var unsafe *pr = NameLookup::representative(prim)
        for var i: usize = 0; i < gps.size() && k < e->args.size(); ++i {
            if gps[i] != &null {
                d->bind(pr, gps[i]->index, e->args[k])
            }

            k += 1
        }
    }

    priv fn _callee_of(self, c: unsafe *CallExpr) -> unsafe *Decl {
        var unsafe *callee = self.tu.strip_parens(c->callee)
        var unsafe *ni     = dyn_cast<NamedIdentExpr>(callee)
        if ni != &null {
            return ni->resolved_decl
        }

        var unsafe *ch = dyn_cast<ChainExpr>(callee)
        if ch != &null && ch->steps.size() > 0 {
            return ch->steps.get(ch->steps.size() - 1)->resolved_decl
        }

        return &null
    }

    priv fn _fields_of(self, d: unsafe *Decl) -> FrozenList<unsafe *Declarations::FieldDecl> {
        if isa<Declarations::ClassDecl>(d) {
            return cast<Declarations::ClassDecl>(d)->fields
        }

        if isa<Declarations::StructDecl>(d) {
            return cast<Declarations::StructDecl>(d)->fields
        }

        if isa<Declarations::UnionDecl>(d) {
            return cast<Declarations::UnionDecl>(d)->fields
        }

        return create_empty_frozen_list<unsafe *Declarations::FieldDecl>()
    }

    priv fn _methods_of(self, d: unsafe *Decl) -> FrozenList<unsafe *Declarations::FunctionDecl> {
        if isa<Declarations::ClassDecl>(d) {
            return cast<Declarations::ClassDecl>(d)->methods
        }

        if isa<Declarations::StructDecl>(d) {
            return cast<Declarations::StructDecl>(d)->methods
        }

        if isa<Declarations::UnionDecl>(d) {
            return cast<Declarations::UnionDecl>(d)->methods
        }

        return create_empty_frozen_list<unsafe *Declarations::FunctionDecl>()
    }

    /// \p row and the rows of its interface's `derives` closure, each once:
    /// a call bound to a base's requirement goes through the BASE's witness
    /// (Compiler/Spec/Witnesses.md#interfaces-case-by-case), so the instance needs that row too, and a base
    /// requirement \p x does not meet is the bound's failure, reported at
    /// \p at like the bound's own. False when one was reported.
    priv fn _push_closure(self,
                          row:        unsafe *ConformanceRow,
                          x:          unsafe *Type,
                          @inout out: cxx::std::vector<unsafe *ConformanceRow>,
                          at:         SourceRange,
                          b:          unsafe *ConstraintExpr) -> bool {
        for var i: usize = 0; i < out.size(); ++i {
            if (out)[i] == row {
                return true
            }
        }

        // One row covers the interface's whole composed requirement list,
        // inherited requirements included (InterfaceComposition): a call
        // through the bound goes through the bound's witness, so there are no
        // base rows to add.
        out.push_back(row)
        return true
    }

    /// ## the table

    /// THE row for (\p x, \p iface): the table's, else built by the
    /// requirement match below and recorded. Never null for an interface
    /// type; `ok` false when some requirement has no implementation on \p x.
    ///
    /// \p declared is the `impl` that declares it, for a GENERIC row (\p x
    /// over that decl's own parameters): the row is born with it, since
    /// codegen spells the partial specialization's head from it.
    ///
    /// Per TU (Compiler/Spec/Interfaces.md#program-wide-rows-per-tu-visibility): the table's row only where this TU can use it
    /// (_usable). Otherwise the match runs again over what this TU sees, and
    /// its result is DETACHED, never the table's: not ok with
    /// ConformanceRow::hidden naming the member this TU cannot see, or, when
    /// it found a different implementation this TU can see, not ok with
    /// `clash` -- one conformance cannot have two (every TU's C++ carries
    /// the same witness). A row that is not ok is never recorded either: it
    /// was one TU's view (or one moment's: the extension index skips a TU
    /// whose types have not been resolved yet), not a fact of the program.
    fn conforms(self,
                x:        unsafe *Type,
                iface:    unsafe *Type,
                declared: unsafe *Decl = &null) -> unsafe *ConformanceRow {
        var unsafe *hit = self.sc->instances->row_find(x, iface)
        if hit != &null && self._usable(hit) {
            return hit
        }

        var unsafe *idecl = self._iface_decl(iface)
        if idecl == &null {
            return &null
        }

        self._hidden = &null

        var row = ConformanceRow()
        row.conformer  = x
        row.iface      = iface
        row.iface_decl = idecl
        row.declared   = declared
        row.ok         = true
        // Parallel to the interface's composed requirement list. An
        // associated type's witness is the conformer's alias (or, for a
        // default, the requirement itself) and its type goes in
        // `assoc_types`; one the conformer does not supply fails the row.
        var decls = cxx::std::vector<unsafe *Decl>()
        var srcs  = cxx::std::vector<unsafe *Type>()
        self._reqs(idecl, iface, &decls, &srcs)
        for var i: usize = 0; i < decls.size(); ++i {
            var unsafe *m = dyn_cast<Declarations::FunctionDecl>(decls[i])
            var w:  unsafe *Decl = &null
            var ea               = cxx::std::vector<unsafe *Type>()
            var at: unsafe *Type = &null
            var unsafe *ta = dyn_cast<Declarations::TypeAliasDecl>(decls[i])
            if ta != &null {
                w = self._assoc_implementation(x, iface, ta, unsafe &at)
                // The supplied type must meet the associated type's own
                // bounds (`type Item impl Display`).
                if w != &null
                    && at != &null
                    && !self._assoc_bounds_met(
                        at,
                        ta,
                        x,
                        if (srcs[i] != &null) => (srcs[i]) else => iface,
                        &row.assoc_rows,
                    ) {
                    w = &null
                }

                if w == &null {
                    row.ok = false
                }
            }

            if m != &null {
                var unsafe *k = self._iface_decl(srcs[i])
                w = self._implementation(x, srcs[i], k, m)
                // A `priv` / `prot` member meets a requirement only for an
                // `impl` declared in its own file (_witness_access_ok).
                if w != &null && !self._witness_access_ok(w, x, idecl) {
                    if self._hidden == &null {
                        self._hidden = w
                    }

                    w = &null
                }

                // A constructor slot's witness may be the record itself (its
                // implicit default constructor), which has no extension.
                var unsafe *wf = dyn_cast<Declarations::FunctionDecl>(w)
                if w == &null || wf != &null && !self._ext_args(wf, x, &ea) {
                    row.ok = false
                }
            }

            row.witnesses.push_back(w)
            row.reqs.push_back(decls[i])
            row.sources.push_back(srcs[i])
            row.assoc_types.push_back(at)
            row.ext_arg_count.push_back(ea.size())
            for var k2: usize = 0; k2 < ea.size(); ++k2 {
                row.ext_args.push_back(ea[k2])
            }
        }

        row.hidden = self._hidden
        if hit != &null {
            if row.ok {
                row.ok    = false
                row.clash = hit
            }

            return self.sc->instances->row_detached(unsafe &row)
        }

        if !row.ok {
            return self.sc->instances->row_detached(unsafe &row)
        }

        row.covered_by = self._covering(x, iface, unsafe &row)
        row.seen_by.push_back(self.sc->ctx->fid)
        return self.sc->instances->row_add(unsafe &row)
    }

    /// ## visibility (the extension-visibility rule, per TU)

    /// The member _implementation skipped last because this TU cannot see
    /// it, though it matched: why a detached row is not ok.
    priv var _hidden: unsafe *Decl = &null
    // The extension-visible set (imports, and what they re-export) lives on
    // SemaContext (sees_extension_file): member and operator lookup filter
    // by the same set.

    /// Table row \p row is usable in this TU: each implementing decl that is
    /// an extension member is in this TU's extension-visible set (an own
    /// member is visible wherever its type is). Remembered on the row
    /// (seen_by), so a second ask is one lookup.
    priv fn _usable(self, row: unsafe *ConformanceRow) -> bool {
        var fid = self.sc->ctx->fid
        if self.sc->instances->row_visible_in(row, fid) {
            return true
        }

        for var i: usize = 0; i < row->witnesses.size(); ++i {
            var unsafe *w = row->witnesses[i]
            if w != &null && !self._sees(w) {
                return false
            }
        }

        self.sc->instances->row_mark_visible(row, fid)
        return true
    }

    /// \p d may implement a requirement here: not an extension member, or
    /// one in a file this TU imports or gets re-exported (sees_extension_file).
    priv fn _sees(self, d: unsafe *Decl) -> bool {
        if decl_extension_of(d) == &null {
            return true
        }

        var fid = self.tu.fid_of(d)
        if fid == self.sc->ctx->fid {
            return true
        }

        return extension_visible(self.sc, decl_extension_of(d), fid)
    }

    /// Whether \p w, the member found to implement a requirement of
    /// \p idecl on \p x, may: a `pub` one always; a `priv` or `prot` one
    /// only when \p x's record declares `impl` of the interface (or one
    /// deriving it) in \p w's own file -- on the record, or on an `extend`
    /// there. The witness that forwards to it is C++ code outside the
    /// record (`I_witness<X>::m`), which reaches a private member only as
    /// a friend, and a record befriends the witnesses of what its own file
    /// declares it implements (InterfaceEmitter::_friends). A structural
    /// conformance from anywhere else would be refused by C++ -- and inside
    /// a concept, silently: the concept turns false.
    priv fn _witness_access_ok(self,
                               w:     unsafe *Decl,
                               x:     unsafe *Type,
                               idecl: unsafe *Declarations::InterfaceDecl) -> bool {
        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(w)
        if f == &null || f->is_implicit || idecl == &null {
            return true
        }

        var unsafe *r = NameLookup::representative(w)
        var        v  = w->visibility
        if v == VisibilityKind::None && r != &null {
            v = r->visibility
        }

        if v != VisibilityKind::Private && v != VisibilityKind::Protected {
            return true
        }

        var unsafe *rd = self.tu.record_decl(canon_unqual(x))
        if rd == &null {
            return true
        }

        var unsafe *rec = NameLookup::representative(
            decl_pattern(NameLookup::representative(rd)),
        )

        var home = self.tu.fid_of(w)
        if self.tu.fid_of(rec) == home {
            if isa<Declarations::ClassDecl>(rec)
                && self._impl_edges_name(
                    &cast<Declarations::ClassDecl>(rec)->implements,
                    idecl,
                ) {
                return true
            }

            if isa<Declarations::StructDecl>(rec)
                && self._impl_edges_name(
                    &cast<Declarations::StructDecl>(rec)->implements,
                    idecl,
                ) {
                return true
            }
        }

        var unsafe *htu = NameLookup::tu_of(w->semantic_dc)
        if htu == &null || htu->program == &null {
            return false
        }

        var *items = &htu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            var item = *items->get(i)
            if item.kind != TopLevelKind::Decl {
                continue
            }

            if self._ext_declares(item.as_decl(), rec, idecl, 0) {
                return true
            }
        }

        return false
    }

    /// \p d, or a decl inside it (a module block, a visibility group), is
    /// an `extend` of \p rec that declares `impl` of \p idecl.
    priv fn _ext_declares(self,
                          d:     unsafe *Decl,
                          rec:   unsafe *Decl,
                          idecl: unsafe *Declarations::InterfaceDecl,
                          depth: u32) -> bool {
        if d == &null || depth > 32 {
            return false
        }

        if isa<Declarations::VisibilityGroupDecl>(d) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(d)
            for var i: usize = 0; i < g->members.size(); ++i {
                if self._ext_declares(g->members[i], rec, idecl, depth + 1) {
                    return true
                }
            }

            return false
        }

        if isa<Declarations::ModuleDecl>(d) {
            var unsafe *dc = unsafe (cast<Declarations::ModuleDecl>(d) as unsafe *DeclContext)
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                if self._ext_declares(
                    *dc->dc_decls.get(i),
                    rec,
                    idecl,
                    depth + 1,
                ) {
                    return true
                }
            }

            return false
        }

        var unsafe *x = dyn_cast<Declarations::ExtensionDecl>(d)
        if x == &null || x->target == &null || x->target->canonical == &null {
            return false
        }

        var unsafe *td = self.tu.record_decl(canon_unqual(x->target->canonical))
        if td == &null {
            return false
        }

        if NameLookup::representative(
            decl_pattern(NameLookup::representative(td)),
        ) != rec {
            return false
        }

        return self._impl_edges_name(&x->implements, idecl)
    }

    /// An edge of \p list names \p idecl or an interface deriving it.
    priv fn _impl_edges_name(self,
                             list:  *FrozenList<Declarations::InheritEdge>,
                             idecl: unsafe *Declarations::InterfaceDecl) -> bool {
        for var i: usize = 0; i < list->size(); ++i {
            var unsafe *e = list->get(i)
            if e == &null || e->base == &null || e->base->canonical == &null {
                continue
            }

            if self._iface_decl_derives(
                self._iface_decl(canon_unqual(e->base->canonical)),
                idecl,
                0,
            ) {
                return true
            }
        }

        return false
    }

    priv fn _iface_decl_derives(self,
                                have:  unsafe *Declarations::InterfaceDecl,
                                want:  unsafe *Declarations::InterfaceDecl,
                                depth: u32) -> bool {
        if have == &null || want == &null || depth > 32 {
            return false
        }

        if (have) == want {
            return true
        }

        for var i: usize = 0; i < have->derives_list.size(); ++i {
            var unsafe *e = have->derives_list.get(i)
            if e == &null || e->base == &null || e->base->canonical == &null {
                continue
            }

            if self._iface_decl_derives(
                self._iface_decl(canon_unqual(e->base->canonical)),
                want,
                depth + 1,
            ) {
                return true
            }
        }

        return false
    }

    /// The GENERIC declared row that covers concrete \p row of instance \p x:
    /// declared on x's pattern (`class <T> Box impl I`) or by a generic
    /// extension of it (`extend <E> Wrap<E> impl I`), its conformer and
    /// interface at x's arguments \p x and \p iface, and its witnesses
    /// \p row's. Then its partial specialization is \p row's witness, and a
    /// full one would only repeat it. Null otherwise: a non-instance, an
    /// explicit specialization's own members, a conformance only structural.
    priv fn _covering(self,
                      x:     unsafe *Type,
                      iface: unsafe *Type,
                      row:   unsafe *ConformanceRow) -> unsafe *ConformanceRow {
        if !isa<RecordType>(x) || x->is_dependent() {
            return &null
        }

        var unsafe *xd = cast<RecordType>(x)->decl
        if xd == &null || !decl_is_instance(xd) {
            return &null
        }

        var unsafe *pat = NameLookup::representative(self.sc->body_of(xd)) // a selected partial's `impl` list.
        if pat == &null {
            return &null
        }

        if isa<Declarations::ClassDecl>(pat) {
            var unsafe *cd = cast<Declarations::ClassDecl>(pat)
            for var i: usize = 0; i < cd->implements.size(); ++i {
                var unsafe *g = self._covers(
                    pat,
                    self._self_type(pat),
                    cd->implements.get(i)->base,
                    x,
                    iface,
                    row,
                )

                if g != &null {
                    return g
                }
            }
        } else if isa<Declarations::StructDecl>(pat) {
            var unsafe *sd = cast<Declarations::StructDecl>(pat)
            for var i: usize = 0; i < sd->implements.size(); ++i {
                var unsafe *g = self._covers(
                    pat,
                    self._self_type(pat),
                    sd->implements.get(i)->base,
                    x,
                    iface,
                    row,
                )

                if g != &null {
                    return g
                }
            }
        }

        var unsafe *exts = self.ml.extensions_of_decl(pat)
        if exts == &null {
            exts = self.ml.extensions_of_decl(self.tu.pattern_of(xd))
        }

        if exts == &null {
            return &null
        }

        for var i: usize = 0; i < exts->size(); ++i {
            var unsafe *e = (*exts)[i]
            if e == &null || e->is_poisoned() || e->target == &null {
                continue
            }

            if decl_generic_params(unsafe (e as unsafe *Decl)).size() == 0 {
                continue
            }

            for var k: usize = 0; k < e->implements.size(); ++k {
                var unsafe *g = self._covers(
                    unsafe (e as unsafe *Decl),
                    self._canon(e->target),
                    e->implements.get(k)->base,
                    x,
                    iface,
                    row,
                )

                if g != &null {
                    return g
                }
            }
        }

        return &null
    }

    /// _covering for one `impl` edge \p base of \p by, whose conformer is
    /// \p gx: its generic row when that covers \p row, else null.
    priv fn _covers(self,
                    by:    unsafe *Decl,
                    gx:    unsafe *Type,
                    base:  unsafe *Type,
                    x:     unsafe *Type,
                    iface: unsafe *Type,
                    row:   unsafe *ConformanceRow) -> unsafe *ConformanceRow {
        if gx == &null || base == &null || !gx->is_dependent() {
            return &null
        }

        var unsafe *bi = self._canon(base)
        if bi == &null || (unsafe (self._iface_decl(bi) as unsafe *Decl)) != row->iface_decl {
            return &null
        }

        var d = Deduction(self.sc, &null)
        if d.unify(gx, x, false) == ImplicitRank::None {
            return &null
        }

        var unsafe *at = d.substitute(bi)
        if at == &null || canon_unqual(at) != iface {
            return &null
        }

        // The table's generic row whoever can see it: coverage decides which
        // C++ specialization is THE witness, a program-wide fact (D7), not a
        // per-TU one.
        var unsafe *g = self.sc->instances->row_find(gx, bi)
        if g == &null {
            g = self.conforms(gx, bi, by)
        }

        if g == &null || !g->ok || g->witnesses.size() != row->witnesses.size() {
            return &null
        }

        for var i: usize = 0; i < g->witnesses.size(); ++i {
            if self._entity(g->witnesses[i]) != self._entity(row->witnesses[i]) {
                return &null
            }
        }

        return g
    }

    /// \p d as one entity across a pattern and its instances: a constructor
    /// slot's witness is the record, `Wrap` in a generic row and `Wrap<i32>`
    /// in a concrete one.
    priv fn _entity(self, d: unsafe *Decl) -> unsafe *Decl {
        if d == &null {
            return &null
        }

        return NameLookup::representative(self.tu.pattern_of(d))
    }

    /// \p idecl's requirement decls and, for each, the interface instance it
    /// came through, at \p iface's arguments. The composed list
    /// (InterfaceComposition); an interface it never composed (it was
    /// poisoned) contributes its own methods.
    priv fn _reqs(self,
                  idecl:        unsafe *Declarations::InterfaceDecl,
                  iface:        unsafe *Type,
                  @inout decls: cxx::std::vector<unsafe *Decl>,
                  @inout srcs:  cxx::std::vector<unsafe *Type>) {
        if idecl->compose_state != 2 {
            for var i: usize = 0; i < idecl->methods.size(); ++i {
                decls.push_back(idecl->methods[i])
                srcs.push_back(iface)
            }

            return
        }

        for var i: usize = 0; i < idecl->requirements.size(); ++i {
            var unsafe *r = idecl->requirements.get(i)
            decls.push_back(r->decl)
            srcs.push_back(self._through_iface(self._canon(r->source), iface))
        }
    }

    /// The arguments \p x binds a GENERIC extension's parameters to, when
    /// \p f is its member (`extend <E> Wrap<E>` reached through `Wrap<i32>`:
    /// [i32]), appended to \p out; nothing for any other \p f. False when
    /// the target does not match \p x or leaves a parameter unbound.
    priv fn _ext_args(self,
                      f:          unsafe *Declarations::FunctionDecl,
                      x:          unsafe *Type,
                      @inout out: cxx::std::vector<unsafe *Type>) -> bool {
        var unsafe *ext = decl_extension_of(f)
        if ext == &null {
            return true
        }

        var eps = decl_generic_params(ext)
        if eps.size() == 0 {
            return true
        }

        var d = Deduction(self.sc, &null)
        // A GENERIC row's conformer is dependent (`Wrap<E>`), which
        // bind_from_extension declines; unified directly, the extension's
        // parameters bind to the row's own (E := E), which the partial
        // specialization then spells by name.
        var dep = x->is_dependent()
        if dep {
            if ext->target == &null || ext->target->canonical == &null {
                return false
            }

            if d.unify(
                canon_unqual(ext->target->canonical),
                canon_unqual(x),
                false,
            ) == ImplicitRank::None {
                return false
            }
        } else if !d.bind_from_extension(f, x) {
            return false
        }

        for var i: usize = 0; i < eps.size(); ++i {
            var unsafe *gp = eps[i]
            if gp == &null {
                return false
            }

            var unsafe *b = d.lookup(NameLookup::representative(ext), gp->index)
            if b == &null {
                b = d.lookup(unsafe (ext as unsafe *Decl), gp->index)
            }

            if b == &null || b->is_dependent() && !dep {
                return false
            }

            out.push_back(b)
        }

        return true
    }

    /// The member of \p x that implements requirement \p m of \p iface, or
    /// null. Every candidate member lookup finds is a decl the row could
    /// forward to; the one whose signature is \p m's exactly wins.
    priv fn _implementation(self,
                            x:     unsafe *Type,
                            iface: unsafe *Type,
                            idecl: unsafe *Declarations::InterfaceDecl,
                            m:     unsafe *Declarations::FunctionDecl) -> unsafe *Decl {
        if m == &null || m->is_poisoned() {
            return &null
        }

        if decl_is_ctor_requirement(m) {
            return self._ctor_implementation(x, iface, idecl, m)
        }

        var cands = cxx::std::vector<unsafe *Decl>()
        self.ml.lookup(x, self._name_of(m), unsafe &cands)
        for var i: usize = 0; i < cands.size(); ++i {
            var unsafe *f = dyn_cast<Declarations::FunctionDecl>(cands[i])
            if f == &null || f->is_poisoned() {
                continue
            }

            if self._owned_by_interface(unsafe (f as unsafe *Decl)) { // a bound's own requirement, never a witness.
                continue
            }

            if !self._signature_matches(f, m, x, iface, idecl) {
                continue
            }

            // An extension this TU does not import implements nothing here
            // (the extension-visibility rule); kept for the diagnostic.
            if !self._sees(unsafe (f as unsafe *Decl)) {
                if self._hidden == &null {
                    self._hidden = NameLookup::representative(
                        unsafe (f as unsafe *Decl),
                    )
                }

                continue
            }

            return NameLookup::representative(unsafe (f as unsafe *Decl))
        }

        // Member lookup does not return an extension this TU does not
        // import, so the skip above never sees it: ask for the hidden
        // extension's members directly, or the miss reads as a signature
        // mismatch instead of "import its module here".
        if self._hidden == &null {
            var hid = cxx::std::vector<unsafe *Decl>()
            self.ml.hidden_extension_members(x, self._name_of(m), unsafe &hid)
            for var j: usize = 0; j < hid.size(); ++j {
                var unsafe *hf = dyn_cast<Declarations::FunctionDecl>(hid[j])
                if hf == &null || hf->is_poisoned() {
                    continue
                }

                if self._signature_matches(hf, m, x, iface, idecl) {
                    self._hidden = NameLookup::representative(
                        unsafe (hf as unsafe *Decl),
                    )

                    break
                }
            }
        }

        return self._native_implementation(x, iface, idecl, m)
    }

    /// An `op ==` requirement (`fn op ==(const self, other: Self) -> bool`)
    /// met by an operator the conformer has with no decl to name: a
    /// builtin's or a pointer's own `==`, or an imported C++ record's,
    /// member or free, which C++ resolves (and checks) where the witness is
    /// instantiated. The requirement itself stands as the witness, as for a
    /// lifecycle slot on a builtin (_transfer_implementation); EmitWitness
    /// spells the specialization member as the native comparison. Without
    /// it no primitive could key a `{K: V}` (Lib/builtin/base/hash.k), and
    /// declaring `op ==` on `i32` in an extension would take over every
    /// `i32 ==` in the program. Reached only when no member matched: a
    /// builtin or a pointer has none, and an imported record's own
    /// `operator==(const X&) const` is not the requirement's Kairo shape but
    /// is what C++ calls for `self == other`. A Kairo record never takes
    /// this path: its declared `op ==` of another shape is a real mismatch.
    priv fn _native_implementation(self,
                                   x:     unsafe *Type,
                                   iface: unsafe *Type,
                                   idecl: unsafe *Declarations::InterfaceDecl,
                                   m:     unsafe *Declarations::FunctionDecl) -> unsafe *Decl {
        if !m->is_operator && self._is_std_hash_slot(x, idecl, m) {
            return m
        }

        if !m->is_operator || !m->is_method() || !m->is_const() {
            return &null
        }

        if m->op_token.size() != 1 || m->op_token[0].kind != TokenKind::OpEqualEqual {
            return &null
        }

        if m->generic_params.size() > 0 || self._arity(m) != 1 {
            return &null
        }

        var unsafe *c = self._canon(x)
        if c == &null {
            return &null
        }

        var native = false
        var k      = self.tu.kind_of(c)
        if k != BuiltinKind::COUNT {
            native = self.tu.is_numeric(c)
                || self.tu.is_bool(c)
                || k == BuiltinKind::Char
                || is_c_character(k)
                || k == BuiltinKind::Byte
        } else if self.tu.pointee(c) != &null {
            native = true
        } else {
            var unsafe *rd = self.tu.record_decl(c)
            native = rd != &null && decl_is_imported(NameLookup::representative(rd))
        }

        if !native {
            return &null
        }

        for var i: usize = 0; i < m->params.size(); ++i {
            var unsafe *mp = m->params[i]
            if mp == &null || mp->is_self {
                continue
            }

            if self._as_conformer(mp->type_, x, iface, idecl, m, m) != c {
                return &null
            }
        }

        if !self.tu.is_bool(
            self._as_conformer(m->return_type, x, iface, idecl, m, m),
        ) {
            return &null
        }

        return m
    }

    /// The Hash lang item's `fn hash(const self) -> usize` on a pointer (its
    /// address), or on an imported C++ type with no `hash` member: met by
    /// `std::hash<X>`, which the
    /// witness calls (`::std::hash<X>{}(*self)`), so a C++ type usable as a
    /// `std::unordered_map` key keys a `{K: V}` with no Kairo code. Whether
    /// `std::hash<X>` is enabled is C++'s to check, at the witness.
    priv fn _is_std_hash_slot(self,
                              x:     unsafe *Type,
                              idecl: unsafe *Declarations::InterfaceDecl,
                              m:     unsafe *Declarations::FunctionDecl) -> bool {
        var unsafe *hd = self.sc->well_known->get(WellKnownType::Hash)
        if hd == &null
            || NameLookup::representative(hd) != NameLookup::representative(
                unsafe (idecl as unsafe *Decl),
            ) {
            return false
        }

        if !m->is_method()
            || !m->is_const()
            || self._arity(m) != 0
            || m->generic_params.size() > 0 {
            return false
        }

        if self.tu.decl_name(unsafe (m as unsafe *Decl)) != "hash" {
            return false
        }

        // A pointer has no extension scope to carry a `hash` (CXXSpell has no
        // scope name for `extend <T> *T`), so its address is its hash.
        if self.tu.pointee(self._canon(x)) != &null {
            return true
        }

        var unsafe *rd = self.tu.record_decl(self._canon(x))
        return rd != &null && decl_is_imported(NameLookup::representative(rd))
    }

    /// What supplies associated-type requirement \p ta of \p iface on
    /// \p x: \p x's alias of that name, or \p ta itself when an explicit
    /// conformance takes its default; null when nothing does (structural
    /// conformance never takes a default). The type goes in \p out --
    /// Substitution::assoc_witness's answer, the same one every use reads.
    /// A dependent \p x (a generic row's `Wrap<E>`) reads its alias through
    /// E, which the partial specialization spells. A generic associated
    /// type (`type <K> Map`) is supplied by a generic alias of the same
    /// arity, and its type is that alias at its own parameters, which the
    /// witness spells as a member alias template.
    priv fn _assoc_implementation(self,
                                  x:     unsafe *Type,
                                  iface: unsafe *Type,
                                  ta:    unsafe *Declarations::TypeAliasDecl,
                                  out:   unsafe *(unsafe *Type)) -> unsafe *Decl {
        var        d  = Deduction(self.sc, &null)
        var unsafe *t = d.assoc_witness(x, iface, ta)
        if t == &null || isa<AssocType>(canon_unqual(t)) {
            return &null
        }

        *out = t
        // The alias, when x declares one (a default has none): codegen
        // spells the type either way, the decl is for the report's note.
        var        cands = cxx::std::vector<unsafe *Decl>()
        var unsafe *imms = self.sc->ctx->get_imm_table()
        self.ml.lookup(
            x,
            DeclName::ident(imms->intern_ident_copy(self.tu.decl_name(ta))),
            unsafe &cands,
        )

        for var i: usize = 0; i < cands.size(); ++i {
            var unsafe *a = dyn_cast<Declarations::TypeAliasDecl>(cands[i])
            if a != &null
                && !a->is_associated
                && a->generic_params.size() == ta->generic_params.size() {
                return NameLookup::representative(cands[i])
            }
        }

        return ta
    }

    /// \p t, supplied for associated type \p ta by conformer \p x through
    /// \p iface, meets every `impl` bound \p ta declares, read for \p x as
    /// every use reads them (Substitution::clause_bounds: `Self` is \p x,
    /// the interface's parameters its arguments, another associated type
    /// \p x's). A bound still dependent after that is not checked here, nor
    /// is a generic associated type's alias at its own parameters.
    priv fn _assoc_bounds_met(self,
                              t:           unsafe *Type,
                              ta:          unsafe *Declarations::TypeAliasDecl,
                              x:           unsafe *Type,
                              iface:       unsafe *Type,
                              @inout rows: cxx::std::vector<unsafe *ConformanceRow>) -> bool {
        if t->is_dependent() && ta->generic_params.size() > 0 {
            return true
        }

        var ready = true
        var none  = cxx::std::vector<unsafe *Type>()
        var bs = Substitution(self.sc).clause_bounds(
            ta,
            x,
            iface,
            unsafe &none,
            unsafe &ready,
        )

        for var i: usize = 0; i < bs.size(); ++i {
            var unsafe *bt = canon_unqual(bs[i])
            if bt->is_dependent() {
                continue
            }

            var unsafe *r = self.conforms(canon_unqual(t), bt)
            if r != &null && !r->ok {
                return false
            }

            // A generic row's dependent supply (`Item = Wrap<N>`) is no row of
            // its own: its instances' rows are, when they are formed.
            if r != &null && !t->is_dependent() {
                rows.push_back(r)
            }
        }

        return true
    }

    /// The constructor of \p x that meets constructor requirement \p m, or
    /// null. Looked up as CallTyping's `_ctor_call` looks up `X(args)`: X's
    /// OWN table under DeclName::ctor(), never member lookup, whose walk
    /// reaches a base's constructors and no extension can add one. A record
    /// that declares none has the implicit default constructor `X()` types
    /// against; the record itself stands for it, so the row is complete. A
    /// builtin has no constructor to call -- `i32()` is SC037E -- and so
    /// meets none.
    priv fn _ctor_implementation(self,
                                 x:     unsafe *Type,
                                 iface: unsafe *Type,
                                 idecl: unsafe *Declarations::InterfaceDecl,
                                 m:     unsafe *Declarations::FunctionDecl) -> unsafe *Decl {
        var unsafe *c = self._canon(x)
        if c == &null {
            return &null
        }

        if m->transfer != Declarations::TransferKind::NotTransfer {
            return self._transfer_implementation(c, m)
        }

        if !isa<RecordType>(c) {
            return &null
        }

        var unsafe *d = self.tu.record_decl(c)
        if d == &null || isa<Declarations::InterfaceDecl>(d) {
            return &null
        }

        var unsafe *dc   = NameLookup::context_of(self.sc->body_of(d)) // an unfilled instance has an empty table; its body's.
        var        cands = cxx::std::vector<unsafe *Decl>()
        if dc != &null {
            var cell = self.sc->lookup.in_context(dc, DeclName::ctor())
            if cell.found() {
                for var i: usize = 0; i < cell.cell->size(); ++i {
                    cands.push_back(cell.cell->get(i))
                }
            }
        }

        if cands.size() == 0 {
            if self._arity(m) == 0 {
                return NameLookup::representative(d)
            }

            return &null
        }

        for var i: usize = 0; i < cands.size(); ++i {
            var unsafe *f = dyn_cast<Declarations::FunctionDecl>(cands[i])
            if f == &null || f->is_poisoned() || f->adt_role != Declarations::AdtRole::None {
                continue
            }

            if self._ctor_matches(f, m, c, iface, idecl) {
                return NameLookup::representative(unsafe (f as unsafe *Decl))
            }
        }

        return &null
    }

    /// A LIFECYCLE requirement (`@copy fn Copyable(self, const other: Self)`)
    /// asks for a category, not a declared constructor (Doc: Interface
    /// Requirements): `@copy` is met by COPY types, `@move` by COPY and
    /// MOVE, NON_TRANSFER by neither -- an implicit transfer counts, and a
    /// builtin is COPY. The record stands as the witness; a builtin has no
    /// decl, so the requirement itself does, which no consumer forwards to
    /// (a constructor slot never reaches a witness member).
    priv fn _transfer_implementation(self,
                                     c: unsafe *Type,
                                     m: unsafe *Declarations::FunctionDecl) -> unsafe *Decl {
        // An open category would silently mean "no witness" for a concrete
        // type (Asked too early, ClassLifecycle).
        var f = lifecycle_of(self.sc)->facts_of_type_concrete(
            c,
            "ConformanceChecking::_transfer_implementation",
        )

        var ok = f.category == LifecycleCategory::Copy
        if m->transfer == Declarations::TransferKind::Move {
            ok = ok || f.category == LifecycleCategory::Move
        }

        if !ok {
            return &null
        }

        var unsafe *d = self.tu.record_decl(c)
        if d != &null {
            return NameLookup::representative(d)
        }

        return unsafe (m as unsafe *Decl)
    }

    /// _signature_matches for a constructor: no receiver constness and no
    /// return type to compare, and a generic record's parameters in the
    /// candidate bound from \p x, as `Box<i32>(n)` binds them.
    priv fn _ctor_matches(self,
                          f:     unsafe *Declarations::FunctionDecl,
                          m:     unsafe *Declarations::FunctionDecl,
                          x:     unsafe *Type,
                          iface: unsafe *Type,
                          idecl: unsafe *Declarations::InterfaceDecl) -> bool {
        if f->generic_params.size() != m->generic_params.size() {
            return false
        }

        if f->params.size() != m->params.size() {
            return false
        }

        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *fp = f->params[i]
            var unsafe *mp = m->params[i]
            if fp == &null || mp == &null {
                return false
            }

            if fp->is_self != mp->is_self {
                return false
            }

            if fp->is_self {
                continue
            }

            if fp->mode != mp->mode || fp->is_pack != mp->is_pack {
                return false
            }

            if self._as_ctor_param(fp->type_, f, x) != self._as_conformer(
                mp->type_,
                x,
                iface,
                idecl,
                m,
                f,
            ) {
                return false
            }
        }

        return true
    }

    /// Constructor \p f's parameter type \p t as `X(args)` sees it: the
    /// record's parameters bound to \p x's arguments, \p f's own left as
    /// themselves. Top-level cv dropped.
    priv fn _as_ctor_param(self,
                           t: unsafe *Type,
                           f: unsafe *Declarations::FunctionDecl,
                           x: unsafe *Type) -> unsafe *Type {
        var unsafe *c = self._canon(t)
        if c == &null || !c->is_dependent() {
            return c
        }

        var d = Deduction(self.sc, &null)
        d.bind_from_record(x)
        var unsafe *frep = NameLookup::representative(
            unsafe (f as unsafe *Decl),
        )

        for var i: usize = 0; i < f->generic_params.size(); ++i {
            var unsafe *gp = f->generic_params[i]
            if gp == &null {
                continue
            }

            d.bind(
                frep,
                gp->index,
                self.sc->types->generic_param(frep, gp->index, gp->is_pack),
            )
        }

        var unsafe *s = d.substitute(c)
        return if (s != &null) => (canon_unqual(s)) else => c
    }

    /// Parameters after the receiver.
    priv fn _arity(self, m: unsafe *Declarations::FunctionDecl) -> usize {
        var n: usize = 0
        for var i: usize = 0; i < m->params.size(); ++i {
            if m->params[i] != &null && !m->params[i]->is_self {
                n += 1
            }
        }

        return n
    }

    priv fn _signature_matches(self,
                               f:     unsafe *Declarations::FunctionDecl,
                               m:     unsafe *Declarations::FunctionDecl,
                               x:     unsafe *Type,
                               iface: unsafe *Type,
                               idecl: unsafe *Declarations::InterfaceDecl) -> bool {
        if f->is_method() != m->is_method() {
            return false
        }

        if f->is_method() && f->is_const() != m->is_const() {
            return false
        }

        // The convention is part of the signature: the witness is called as
        // the requirement says.
        if f->call_conv != m->call_conv {
            return false
        }

        if f->generic_params.size() != m->generic_params.size() {
            return false
        }

        if f->params.size() != m->params.size() {
            return false
        }

        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *fp = f->params[i]
            var unsafe *mp = m->params[i]
            if fp == &null || mp == &null {
                return false
            }

            if fp->is_self != mp->is_self {
                return false
            }

            if fp->is_self {
                continue
            }

            if fp->mode != mp->mode || fp->is_pack != mp->is_pack {
                return false
            }

            if self._as_candidate(fp->type_, f, x) != self._as_conformer(
                mp->type_,
                x,
                iface,
                idecl,
                m,
                f,
            ) {
                return false
            }
        }

        return self._as_candidate(f->return_type, f, x) == self._as_conformer(
            m->return_type,
            x,
            iface,
            idecl,
            m,
            f,
        )
    }

    /// Candidate \p f's type \p t as reached through \p x: a generic
    /// extension's parameters bound from \p x (its target unified with it),
    /// \p f's own parameters left as themselves. Top-level cv dropped.
    priv fn _as_candidate(self,
                          t: unsafe *Type,
                          f: unsafe *Declarations::FunctionDecl,
                          x: unsafe *Type) -> unsafe *Type {
        var unsafe *c = self._canon(t)
        if c == &null || !c->is_dependent() {
            return c
        }

        var d = Deduction(self.sc, &null)
        if !d.bind_from_extension(f, x) {
            return c
        }

        // A member of a generic record (`class <T> Holder { fn first() ->
        // T }`) reached through an instance reads T at its argument, as a
        // call on that instance does.
        if decl_extension_of(unsafe (f as unsafe *Decl)) == &null
            && isa<RecordType>(canon_unqual(x)) {
            d.bind_from_record(canon_unqual(x))
        }

        var unsafe *frep = NameLookup::representative(
            unsafe (f as unsafe *Decl),
        )

        for var i: usize = 0; i < f->generic_params.size(); ++i {
            var unsafe *gp = f->generic_params[i]
            if gp == &null {
                continue
            }

            d.bind(
                frep,
                gp->index,
                self.sc->types->generic_param(frep, gp->index, gp->is_pack),
            )
        }

        var unsafe *s = d.substitute(c)
        return if (s != &null) => (canon_unqual(s)) else => c
    }

    /// Requirement type \p t as conformer \p x sees it: the interface's own
    /// parameters bound to \p iface's arguments, a GENERIC requirement's own
    /// parameters to candidate \p f's by position (`fn <U> put(u: U)` and
    /// `fn <V> put(v: V)` are one signature), then `Self` replaced by \p x.
    /// Top-level cv dropped, as for any signature compare.
    priv fn _as_conformer(self,
                          t:     unsafe *Type,
                          x:     unsafe *Type,
                          iface: unsafe *Type,
                          idecl: unsafe *Declarations::InterfaceDecl,
                          m:     unsafe *Declarations::FunctionDecl,
                          f:     unsafe *Declarations::FunctionDecl) -> unsafe *Type {
        var unsafe *c = self._canon(t)
        if c == &null {
            return &null
        }

        var d = Deduction(self.sc, &null)
        // Self first: in a GENERIC interface it is `I<T>` over I's own
        // parameters, which the substitution below would turn into an
        // instance (`I<i32>`) that no longer reads as Self.
        // A dependent x waits: the substitution cannot bind the caller's
        // parameters, and would give up on the whole type.
        if !x->is_dependent() {
            c = d.replace_self(c, unsafe (idecl as unsafe *Decl), x, true)
        }

        if c->is_dependent() {
            d.bind_from_record(iface)
            var unsafe *mrep = NameLookup::representative(
                unsafe (m as unsafe *Decl),
            )

            var unsafe *frep = NameLookup::representative(
                unsafe (f as unsafe *Decl),
            )

            for var i: usize = 0; i < m->generic_params.size(); ++i {
                var unsafe *gp = m->generic_params[i]
                if gp == &null {
                    continue
                }

                d.bind(
                    mrep,
                    gp->index,
                    self.sc->types->generic_param(
                        frep,
                        f->generic_params[i]->index,
                        gp->is_pack,
                    ),
                )
            }

            var unsafe *s = d.substitute(c)
            if s != &null {
                c = s
            }
        }

        return canon_unqual(
            d.replace_self(c, unsafe (idecl as unsafe *Decl), x),
        )
    }

    priv fn _canon(self, t: unsafe *Type) -> unsafe *Type {
        if t == &null {
            return &null
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        return canon_unqual(c)
    }

    /// The requirement's name in THIS TU's imm space: the interface may be
    /// another file's, and MemberLookup keys identifiers by the asking TU.
    priv fn _name_of(self, m: unsafe *Declarations::FunctionDecl) -> DeclName {
        if m->is_operator {
            var k0 = TokenKind::TkUnknown
            var k1 = TokenKind::TkUnknown
            var k2 = TokenKind::TkUnknown
            if m->op_token.size() > 0 {
                k0 = m->op_token[0].kind
            }

            if m->op_token.size() > 1 {
                k1 = m->op_token[1].kind
            }

            // `op []=` is three tokens (DeclName::op_name_of).
            if m->op_token.size() > 2 {
                k2 = m->op_token[2].kind
            }

            return DeclName::op_name_of(k0, k1, k2)
        }

        var unsafe *imms = self.sc->ctx->get_imm_table()
        return DeclName::ident(
            imms->intern_ident_copy(
                self.tu.decl_name(unsafe (m as unsafe *Decl)),
            ),
        )
    }

    /// ## bounds

    /// Every `impl` conjunct of \p e, in clause order (RequiresDesugar hoisted
    /// the inline bounds in; ConstraintExtraction splits it the same way).
    priv fn _impl_bounds(self,
                         e:   unsafe *Expr,
                         out: unsafe *cxx::std::vector<unsafe *ConstraintExpr>) {
        if e == &null {
            return
        }

        if e->kind == ExprKind::BinaryOperatorExpr {
            var unsafe *b = cast<BinaryOperatorExpr>(e)
            if b->op_token.kind == TokenKind::OpAmpAmp || b->op_token.kind == TokenKind::KwAnd {
                self._impl_bounds(b->lhs, out)
                self._impl_bounds(b->rhs, out)
                return
            }
        }

        if e->kind != ExprKind::ConstraintExpr {
            return
        }

        var unsafe *c = cast<ConstraintExpr>(e)
        if !c->is_derives() {
            out->push_back(c)
        }
    }

    /// The generic parameter of \p owner that conjunct \p c constrains, or
    /// null (a conjunct on an enclosing record's parameter).
    priv fn _param_named(self,
                         c:     unsafe *ConstraintExpr,
                         owner: unsafe *Decl) -> unsafe *Declarations::GenericParamDecl {
        var unsafe *id = dyn_cast<NamedIdentExpr>(c->lhs)
        if id == &null {
            return &null
        }

        var unsafe *gp = dyn_cast<Declarations::GenericParamDecl>(
            id->resolved_decl,
        )

        if gp == &null {
            return &null
        }

        var gps = decl_generic_params(owner)
        for var i: usize = 0; i < gps.size(); ++i {
            if gps[i] == gp {
                return gp
            }
        }

        return &null
    }

    /// The bound's interface at instance \p e: `T impl Container<U>` with
    /// U bound to e's argument.
    priv fn _bound_iface(self,
                         c:     unsafe *ConstraintExpr,
                         owner: unsafe *Decl,
                         e:     unsafe *InstanceEntry) -> unsafe *Type {
        if c->rhs == &null || c->rhs->canonical == &null {
            return &null
        }

        var unsafe *t = canon_unqual(c->rhs->canonical)
        if !t->is_dependent() {
            return t
        }

        var d   = Deduction(self.sc, &null)
        var gps = decl_generic_params(owner)
        for var i: usize = 0; i < gps.size() && i < e->args.size(); ++i {
            if gps[i] == &null {
                continue
            }

            d.bind(owner, gps[i]->index, e->args[i])
        }

        var unsafe *s = d.substitute(t)
        return if (s != &null) => (canon_unqual(s)) else => &null
    }

    /// Base interface \p base, written in a `derives` edge of \p derived's
    /// declaration, at \p derived's arguments.
    priv fn _through_iface(self, base: unsafe *Type, derived: unsafe *Type) -> unsafe *Type {
        if !base->is_dependent() {
            return base
        }

        var d = Deduction(self.sc, &null)
        d.bind_from_record(derived)
        var unsafe *s = d.substitute(base)
        return if (s != &null) => (canon_unqual(s)) else => base
    }

    priv fn _iface_decl(self, iface: unsafe *Type) -> unsafe *Declarations::InterfaceDecl {
        if iface == &null || !isa<RecordType>(iface) {
            return &null
        }

        var unsafe *d = NameLookup::representative(
            self.tu.pattern_of(cast<RecordType>(iface)->decl),
        )

        return dyn_cast<Declarations::InterfaceDecl>(d)
    }

    priv fn _owned_by_interface(self, d: unsafe *Decl) -> bool {
        if d->semantic_dc == &null {
            return false
        }

        var unsafe *home = (d->semantic_dc)->owner_decl()
        return home != &null && isa<Declarations::InterfaceDecl>(home)
    }

    /// ## the diagnostic

    /// `scale`, or `op +=` for an operator: an operator's name token is its
    /// operator token, which decl_name cannot spell as an identifier.
    priv fn _req_name(self, m: unsafe *Declarations::FunctionDecl) -> string {
        if !m->is_operator {
            return self.tu.decl_name(unsafe (m as unsafe *Decl))
        }

        var unsafe *ctx = NameLookup::ctx_of(unsafe (m as unsafe *Decl))
        var        s    = "op "
        for var i: usize = 0; i < m->op_token.size(); ++i {
            s += ctx->get_spelling(m->op_token[i])
        }

        return s
    }

    /// `Counter(i32, Counter)`: constructor requirement \p m as conformer
    /// \p x would declare it, Self and the interface's parameters replaced.
    priv fn _ctor_spelling(self,
                           m:     unsafe *Declarations::FunctionDecl,
                           x:     unsafe *Type,
                           iface: unsafe *Type,
                           idecl: unsafe *Declarations::InterfaceDecl) -> string {
        var s        = self.tu.str(x) + "("
        var k: usize = 0
        for var i: usize = 0; i < m->params.size(); ++i {
            var unsafe *p = m->params[i]
            if p == &null || p->is_self {
                continue
            }

            if k > 0 {
                s += ", "
            }

            s += self.tu.str(
                self._as_conformer(p->type_, x, iface, idecl, m, m),
            )

            k += 1
        }

        return s + ")"
    }

    /// \p e, when given, is the instance whose bound failed: a reached one
    /// gets its instantiation chain (chain_notes).
    priv fn _report(self,
                    at:    SourceRange,
                    b:     unsafe *ConstraintExpr,
                    x:     unsafe *Type,
                    iface: unsafe *Type,
                    row:   unsafe *ConformanceRow,
                    e:     unsafe *InstanceEntry = &null) {
        var xs                                          = self.tu.str(x)
        var is                                          = self.tu.str(iface)
        var missing                                     = ""
        var req:    unsafe *Declarations::FunctionDecl  = &null
        var areq:   unsafe *Declarations::TypeAliasDecl = &null
        if row != &null {
            var decls = cxx::std::vector<unsafe *Decl>()
            var srcs  = cxx::std::vector<unsafe *Type>()
            self._reqs(
                cast<Declarations::InterfaceDecl>(row->iface_decl),
                row->iface,
                &decls,
                &srcs,
            )

            // A missing associated type first: every requirement that names
            // it then fails too, and only it says why.
            for var i: usize = 0; i < row->witnesses.size() && i < decls.size(); ++i {
                if row->witnesses[i] != &null {
                    continue
                }

                var unsafe *ta = dyn_cast<Declarations::TypeAliasDecl>(decls[i])
                if ta != &null {
                    areq = ta
                    break
                }
            }

            for var i: usize = 0; areq == &null && i < row->witnesses.size() && i < decls.size(); ++i {
                if row->witnesses[i] != &null {
                    continue
                }

                var unsafe *f = dyn_cast<Declarations::FunctionDecl>(decls[i])
                if f == &null {
                    continue
                }

                req     = f
                missing = self._req_name(req)
                break
            }
        }

        if row != &null && row->clash != &null {
            self._report_clash(at, b, xs, is, row, e)
            return
        }

        if areq != &null {
            var        an   = self.tu.decl_name(unsafe (areq as unsafe *Decl))
            var        dd   = Deduction(self.sc, &null)
            var unsafe *sup = dd.assoc_witness(x, row->iface, areq)
            if sup != &null && !isa<AssocType>(canon_unqual(sup)) {
                // Supplied, but not meeting the associated type's own bounds.
                var ss = self.tu.str(sup)
                var bd = self.sc->diag->report(
                    DiagID::SC161E,
                    at.start,
                    f"'{xs}' does not conform to '{is}': its associated type '{an}' is '{ss}', which does not meet the bounds '{an}' declares",
                )

                bd.first(at)
                if b != &null {
                    bd.note(b->range.start, f"required by this bound")->child_first(
                        b->range,
                    )
                }

                bd.note(
                    areq->range.start,
                    f"'{an}' and its bounds are declared here",
                )->child_first(areq->range)

                if e != &null {
                    self.chain_notes(unsafe &bd, e)
                }

                bd.emit()
                return
            }

            // Two interfaces x declares each give the inherited requirement a
            // default, and they differ: which one applies would depend on the
            // path (interfaces.md, Associated types and inheritance), so none
            // does. x has to say.
            var dtys   = cxx::std::vector<unsafe *Type>()
            var dnodes = cxx::std::vector<unsafe *Type>()
            var dins   = cxx::std::vector<unsafe *Decl>()
            dd.derived_defaults(x, areq, unsafe &self.ml, &dtys, &dnodes, &dins)
            if dtys.size() > 1 {
                var d0 = self.tu.str(dtys[0])
                var d1 = self.tu.str(dtys[1])
                var i0 = self.tu.decl_name(dins[0])
                var i1 = self.tu.decl_name(dins[1])
                var cd = self.sc->diag->report(
                    DiagID::SC161E,
                    at.start,
                    f"'{xs}' does not conform to '{is}': its interfaces give associated type '{an}' two defaults, '{d0}' from '{i0}' and '{d1}' from '{i1}'",
                )

                cd.first(at)
                if b != &null {
                    cd.note(b->range.start, f"required by this bound")->child_first(
                        b->range,
                    )
                }

                cd.note(dnodes[0]->range.start, f"'{i0}' gives it '{d0}' here")->child_first(
                    dnodes[0]->range,
                )

                cd.note(
                    dnodes[1]->range.start,
                    f"'{i1}' gives it '{d1}' here; declare 'type {an} = ...' in '{xs}' to choose",
                )->child_first(dnodes[1]->range)
                if e != &null {
                    self.chain_notes(unsafe &cd, e)
                }

                cd.emit()
                return
            }

            // Declared, but not in the requirement's shape: a generic
            // associated type needs a generic alias of its arity, and a plain
            // one a plain alias.
            var        acands = cxx::std::vector<unsafe *Decl>()
            var unsafe *aimms = self.sc->ctx->get_imm_table()
            self.ml.lookup(
                x,
                DeclName::ident(aimms->intern_ident_copy(an)),
                unsafe &acands,
            )

            for var i: usize = 0; i < acands.size(); ++i {
                var unsafe *al = dyn_cast<Declarations::TypeAliasDecl>(
                    acands[i],
                )

                if al == &null
                    || al->is_associated
                    || al->generic_params.size() == areq->generic_params.size() {
                    continue
                }

                var want = areq->generic_params.size()
                var have = al->generic_params.size()
                var sd = self.sc->diag->report(
                    DiagID::SC161E,
                    at.start,
                    f"'{xs}' does not conform to '{is}': its '{an}' takes {have} generic parameter(s), and the associated type takes {want}",
                )

                sd.first(at)
                if b != &null {
                    sd.note(b->range.start, f"required by this bound")->child_first(
                        b->range,
                    )
                }

                sd.note(al->range.start, f"'{xs}' declares '{an}' here")->child_first(
                    al->range,
                )

                sd.note(areq->range.start, f"'{an}' is required here")->child_first(
                    areq->range,
                )

                if e != &null {
                    self.chain_notes(unsafe &sd, e)
                }

                sd.emit()
                return
            }

            // interfaces.md, Defaults: a structural conformer declares every
            // associated type; only an explicit `impl` takes a default.
            var ad = self.sc->diag->report(
                DiagID::SC161E,
                at.start,
                f"'{xs}' does not conform to '{is}': it declares no associated type '{an}'",
            )

            ad.first(at)
            if b != &null {
                ad.note(b->range.start, f"required by this bound")->child_first(
                    b->range,
                )
            }

            if areq->aliased != &null && row->declared == &null {
                ad.note(
                    areq->range.start,
                    f"'{an}' has a default, but a default applies only to a type that declares 'impl {is}'",
                )->child_first(areq->range)
            } else {
                ad.note(areq->range.start, f"'{an}' is required here")->child_first(
                    areq->range,
                )
            }

            if e != &null {
                self.chain_notes(unsafe &ad, e)
            }

            ad.emit()
            return
        }

        var msg      = f"'{xs}' does not conform to '{is}'"
        var req_note = f"'{missing}' is required here"
        if req != &null && decl_is_ctor_requirement(req) {
            // Named as the conformer's constructor would be, since that is what
            // is missing: the requirement's own name is the interface's.
            var ctor = self._ctor_spelling(
                req,
                x,
                row->iface,
                cast<Declarations::InterfaceDecl>(row->iface_decl),
            )

            msg      = f"'{xs}' does not conform to '{is}': no constructor '{ctor}'"
            req_note = "the constructor is required here"
            // A lifecycle requirement asks for a category, which is what to
            // name: the transfer constructor may well be implicit.
            if req->transfer == Declarations::TransferKind::Copy {
                msg = f"'{xs}' does not conform to '{is}': '{xs}' is not a COPY type"
            }

            if req->transfer == Declarations::TransferKind::Move {
                msg = f"'{xs}' does not conform to '{is}': '{xs}' is neither COPY nor MOVE"
            }
        } else if missing.size() > 0 && row->hidden != &null && self._sees(row->hidden) {
            // Hidden by its visibility, not by an import (_witness_access_ok).
            var unsafe *hr = row->hidden
            var unsafe *hf = cast<Declarations::FunctionDecl>(hr)
            var        hn  = self._req_name(hf)
            var b2 = self.sc->diag->report(
                DiagID::SC162E,
                at.start,
                f"'{xs}' does not conform to '{is}': its '{hn}' is not public, and its file declares no 'impl {is}'",
            )

            b2.first(at)
            if b != &null {
                b2.note(b->range.start, f"required by this bound")->child_first(
                    b->range,
                )
            }

            if req != &null {
                b2.note(req->range.start, req_note)->child_first(req->range)
            }

            var hat = if (hf->is_operator && hf->op_token.size() > 0) => (hf->op_token[0].range)
                      else => decl_name_tok(hr).range
            b2.note(
                hat.start,
                f"'{hn}' is declared here: a private or protected member implements a requirement only for an 'impl' declared in its own file",
            )->child_first(hat)
            var written = hr->visibility_range()
            if written.is_valid() {
                b2.fix(written, "pub", f"make '{hn}' public")
            }

            if e != &null {
                self.chain_notes(unsafe &b2, e)
            }

            b2.emit()
            return
        } else if missing.size() > 0 && row->hidden != &null {
            msg = f"'{xs}' does not conform to '{is}' here: '{missing}' is implemented by an extension this file does not import"
        } else if missing.size() > 0 {
            msg = f"'{xs}' does not conform to '{is}': no member '{missing}' with the requirement's signature"
        }

        var d = self.sc->diag->report(DiagID::SC162E, at.start, msg)
        d.first(at)
        if b != &null {
            d.note(b->range.start, f"required by this bound")->child_first(
                b->range,
            )
        }

        if req != &null {
            d.note(req->range.start, req_note)->child_first(req->range)
        }

        if missing.size() > 0 && row->hidden != &null {
            d.note(
                row->hidden->range.start,
                "this extension member implements it, in a file this one does not import; import its module here to use the conformance",
            )->child_first(row->hidden->range)
        }

        if e != &null {
            self.chain_notes(unsafe &d, e)
        }

        d.emit()
    }

    /// Detached \p row found an implementation of (\p xs, \p is) that this
    /// TU sees and that differs from the table's (ConformanceRow::clash):
    /// one conformance with two implementations, which no TU's C++ can hold
    /// both of (one witness specialization per conformance, ODR).
    priv fn _report_clash(self,
                          at:       SourceRange,
                          b:        unsafe *ConstraintExpr,
                          const xs: string,
                          const is: string,
                          row:      unsafe *ConformanceRow,
                          e:        unsafe *InstanceEntry) {
        var unsafe *other = row->clash
        var d = self.sc->diag->report(
            DiagID::SC163E,
            at.start,
            f"'{xs}' conforms to '{is}' through a different implementation here than elsewhere in the program; a conformance has one implementation",
        )

        d.first(at)
        if b != &null {
            d.note(b->range.start, f"required by this bound")->child_first(
                b->range,
            )
        }

        for var i: usize = 0; i < row->witnesses.size() && i < other->witnesses.size(); ++i {
            var unsafe *mine   = row->witnesses[i]
            var unsafe *theirs = other->witnesses[i]
            if mine == &null || theirs == &null || self._entity(mine) == self._entity(theirs) {
                continue
            }

            d.note(
                mine->range.start,
                "this implementation is the one visible here",
            )->child_first(mine->range)

            d.note(
                theirs->range.start,
                "this one implements it for another file of the program",
            )->child_first(theirs->range)
            break
        }

        if e != &null {
            self.chain_notes(unsafe &d, e)
        }

        d.emit()
    }
}
