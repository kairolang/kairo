/// --- The Kairo Project ------------------------- Sema/Type/TypeUtil.k --- ///
///
///   \brief Read-only queries over canonical types and decls that every typer
///          mixin needs and that belong to none of them. A component held by
///          value on ExprTyper; no state beyond the SemaContext handle.
///
///   Nothing here diagnoses, allocates, or writes a slot.
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

import AST::ASTSupport::{
    FrozenList,
    create_empty_frozen_list,
}
import AST::Context::SymbolTable::DeclName
import AST::DeclFacts::{
    decl_generic_params,
    decl_is_imported,
    decl_is_instance,
    decl_only_forward,
    decl_pattern,
}
import AST::Kind::DeclKind::{
    DeclKind,
    to_string,
}
import AST::Kind::ExprKind::{
    ExprKind,
    to_string,
}
import AST::Kind::TypeKind::{
    TypeKind,
    to_string,
}
import AST::LangItems::{
    LangAttrs,
    WellKnownType,
    to_string,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,  BuiltinKind,  BuiltinType,     QUAL_CONST,         QUAL_VOLATILE, QualifiedType,
    RecordType, builtin_info, canon_has_const, canon_has_volatile, canon_quals,   canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    ConstraintExpr,
    ListLiteralExpr,
    ParenExpr,
}
import AST::Node::PrimaryExpressions::{
    NamedIdentExpr,
    StringLiteralExpr,
}
import AST::Node::Types
import AST::OperatorFacts::OperatorFacts
import AST::ParamMode::param_mode_prefix
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::SemaContext
import Token::TokenKind::TokenKind

/// The pointer levels of a canonical type (TypeUtil::pointer_shape): how
/// many, whether the outermost is `unsafe`, and what is under the last.
pub struct PointerShape {
    var depth:        u32          = 0
    var outer_unsafe: bool         = false
    var leaf:         unsafe *Type = &null
}

pub class TypeUtil {
    pub var sc: unsafe *SemaContext

    fn TypeUtil(self) {
        self.sc = &null
    }

    pub fn TypeUtil(self, sc: unsafe *SemaContext) {
        self.sc = sc
    }

    /// # builtins

    fn builtin(self, b: BuiltinKind) -> unsafe *Type {
        return self.sc->builtin(b)
    }

    /// COUNT when \p t is not a builtin.
    fn kind_of(self, t: unsafe *Type) -> BuiltinKind {
        var unsafe *u = canon_unqual(t)
        if u == &null || !isa<BuiltinType>(u) {
            return BuiltinKind::COUNT
        }

        return cast<BuiltinType>(u)->builtin
    }

    fn is_builtin(self, t: unsafe *Type, b: BuiltinKind) -> bool {
        return self.kind_of(t) == b
    }

    fn is_void(self, t: unsafe *Type) -> bool {
        return self.is_builtin(t, BuiltinKind::Void)
    }

    fn is_bool(self, t: unsafe *Type) -> bool {
        return self.is_builtin(t, BuiltinKind::Bool)
    }

    fn is_never(self, t: unsafe *Type) -> bool {
        return self.is_builtin(t, BuiltinKind::Never)
    }

    fn is_integer(self, t: unsafe *Type) -> bool {
        var k = self.kind_of(t)
        if k == BuiltinKind::COUNT {
            return false
        }

        return builtin_info(k)->is_integer()
    }

    fn is_float(self, t: unsafe *Type) -> bool {
        var k = self.kind_of(t)
        if k == BuiltinKind::COUNT {
            return false
        }

        return builtin_info(k)->is_float()
    }

    fn is_numeric(self, t: unsafe *Type) -> bool {
        return self.is_integer(t) || self.is_float(t)
    }

    fn is_signed_int(self, t: unsafe *Type) -> bool {
        var k = self.kind_of(t)
        if k == BuiltinKind::COUNT {
            return false
        }

        return builtin_info(k)->is_integer() && builtin_info(k)->is_signed()
    }

    /// Width of an integer builtin, target width for usize/isize, 0 otherwise.
    fn int_bits(self, t: unsafe *Type) -> usize {
        if !self.is_integer(t) {
            return 0
        }

        return t->size_bits
    }

    /// # structural shapes
    ///
    /// Cv is not shape. Every query here answers for the unqualified type; a
    /// caller that wants the qualifier asks quals().

    fn pointee(self, t: unsafe *Type) -> unsafe *Type {
        var unsafe *u = canon_unqual(t)
        if u == &null || !isa<Types::PointerType>(u) {
            return &null
        }

        return cast<Types::PointerType>(u)->pointee
    }

    /// C++'s `std::nullptr_t`, the type of an imported `nullptr` and so of
    /// `&null` passed to C++ (one node in the store, however it is reached).
    fn nullptr_t_type(self) -> unsafe *Type {
        return self.sc->types->nullptr_t()
    }

    fn is_nullptr_t(self, t: unsafe *Type) -> bool {
        var unsafe *u = canon_unqual(t)
        return u != &null && isa<Types::OpaqueFFIType>(u) && u == self.nullptr_t_type()
    }

    /// Requires PointerType::is_unsafe on canonical nodes (see spec).
    fn is_unsafe_ptr(self, t: unsafe *Type) -> bool {
        var unsafe *u = canon_unqual(t)
        if u == &null || !isa<Types::PointerType>(u) {
            return false
        }

        return cast<Types::PointerType>(u)->is_unsafe
    }

    fn nullable_inner(self, t: unsafe *Type) -> unsafe *Type {
        var unsafe *u = canon_unqual(t)
        if u == &null || !isa<Types::NullableType>(u) {
            return &null
        }

        return cast<Types::NullableType>(u)->inner
    }

    /// `T?` -> `T`, `T` -> `T`.
    fn strip_nullable(self, t: unsafe *Type) -> unsafe *Type {
        var unsafe *i = self.nullable_inner(t)
        return if (i != &null) => (i) else => t
    }

    /// \p t's pointer levels, each pointee read canonical and unqualified:
    /// `unsafe **i32` is {2, true, i32}, a non-pointer {0, false, \p t}. What
    /// a pointer shorthand (`var *y = e`, Compiler/Spec/Nullables.md#declaration-shorthands) states, so its
    /// check and its lint count the same stars.
    fn pointer_shape(self, t: unsafe *Type) -> PointerShape {
        var        out = PointerShape{}
        var unsafe *p  = t
        while p != &null && isa<Types::PointerType>(p) {
            if out.depth == 0 {
                out.outer_unsafe = cast<Types::PointerType>(p)->is_unsafe
            }

            out.depth += 1
            p = canon_unqual(cast<Types::PointerType>(p)->pointee)
        }

        out.leaf = p
        return out
    }

    /// Whether `a === b` compares POINTEES (Compiler/Spec/Nullables.md#identity): when a
    /// nullable operand holds a pointer, `==` would compare addresses, and
    /// `===` goes one level down. Asked by OperatorTyping, which types the
    /// compare, and CoalesceLowering, which builds it: one rule for both.
    fn identity_derefs(self, a: unsafe *Type, b: unsafe *Type) -> bool {
        var unsafe *an = self.nullable_inner(self.as_value(a))
        var unsafe *bn = self.nullable_inner(self.as_value(b))
        if an != &null && self.pointee(an) != &null {
            return true
        }

        return bn != &null && self.pointee(bn) != &null
    }

    /// A type read as a VALUE: a C++ reference is its referee ([expr.type]/1,
    /// the lvalue-to-rvalue read), and top-level cv is gone. What every
    /// operator classification wants; Conversion::implicit already does the
    /// same on its own path.
    fn as_value(self, t: unsafe *Type) -> unsafe *Type {
        var unsafe *u = t
        if u == &null {
            return &null
        }

        if isa<Types::CXXLValueRefType>(u) {
            u = cast<Types::CXXLValueRefType>(u)->referee
        } else if isa<Types::CXXRValueRefType>(u) {
            u = cast<Types::CXXRValueRefType>(u)->referee
        }

        return canon_unqual(u)
    }

    fn record_decl(self, t: unsafe *Type) -> unsafe *Decl {
        var unsafe *u = canon_unqual(t)
        if u == &null || !isa<RecordType>(u) {
            return &null
        }

        return cast<RecordType>(u)->decl
    }

    /// The interfaces a bounded generic parameter \p t promises, as their
    /// canonical instances (`T impl Same`, `T impl Container<U>`), or none
    /// when \p t is not a bare parameter or has no interface bound. The
    /// parameter half of Substitution::bound_ifaces, which every reader
    /// goes through: an associated type's bounds need its base substituted
    /// in, which this layer cannot do.
    fn bound_ifaces(self, t: unsafe *Type) -> cxx::std::vector<unsafe *Type> {
        var        out = cxx::std::vector<unsafe *Type>()
        var unsafe *c  = canon_unqual(t)
        if c == &null || !isa<Types::GenericParamType>(c) {
            return out
        }

        var unsafe *g = cast<Types::GenericParamType>(c)
        var        it = self.sc->bounds.find(g->owner as usize as u64)
        if it == self.sc->bounds.end() {
            return out
        }

        var *_set = &it->second
        for var i: usize = 0; i < _set->impl_constraints.size(); ++i {
            var unsafe *k  = _set->impl_constraints[i]
            var unsafe *id = dyn_cast<NamedIdentExpr>(k->lhs)
            if id == &null {
                continue
            }

            var unsafe *gp = dyn_cast<Declarations::GenericParamDecl>(id->resolved_decl)
            if gp == &null || gp->index != g->param_index {
                continue
            }

            if NameLookup::representative(gp->owner) != NameLookup::representative(g->owner) {
                continue
            }

            if k->rhs == &null || k->rhs->canonical == &null {
                continue
            }

            out.push_back(canon_unqual(k->rhs->canonical))
        }

        return out
    }

    /// The bases a generic parameter \p t's `derives` bounds promise
    /// (`X derives Mixin<X>`), as canonicals, in clause order; none when
    /// \p t is not a bare parameter. bound_ifaces' twin over the other half
    /// of the bound table: what lets a CRTP base cast itself down to X.
    fn bound_bases(self, t: unsafe *Type) -> cxx::std::vector<unsafe *Type> {
        var        out = cxx::std::vector<unsafe *Type>()
        var unsafe *c  = canon_unqual(t)
        if c == &null || !isa<Types::GenericParamType>(c) {
            return out
        }

        var unsafe *g = cast<Types::GenericParamType>(c)
        var        it = self.sc->bounds.find(g->owner as usize as u64)
        if it == self.sc->bounds.end() {
            return out
        }

        var *_set = &it->second
        for var i: usize = 0; i < _set->derives_constraints.size(); ++i {
            var unsafe *k  = _set->derives_constraints[i]
            var unsafe *id = dyn_cast<NamedIdentExpr>(k->lhs)
            if id == &null {
                continue
            }

            var unsafe *gp = dyn_cast<Declarations::GenericParamDecl>(id->resolved_decl)
            if gp == &null || gp->index != g->param_index {
                continue
            }

            if NameLookup::representative(gp->owner) != NameLookup::representative(g->owner) {
                continue
            }

            if k->rhs == &null || k->rhs->canonical == &null {
                continue
            }

            out.push_back(canon_unqual(k->rhs->canonical))
        }

        return out
    }

    /// The declaration of \p t when it is a generic parameter whose body is
    /// checked against its bounds (Compiler/Spec/Generics.md#decisions): a bare parameter, a pack's
    /// included (an element `for x in xs` binds has the pack's type, and is
    /// held to the bounds every element meets), no `: type` (the
    /// C++-checked regime, D1), and no `derives` bound
    /// (its conversions, f-string holes and patterns would need the base's
    /// members as well as bound_ifaces, which those paths do not read yet;
    /// its OPERATORS do, see op_checked_param). Null for anything else,
    /// including a dependent composite (`*T`, `Rep<T>`), whose own rules
    /// apply. What such a parameter can do is exactly what bound_ifaces
    /// grants: an operator, a conversion, an interpolation or a pattern its
    /// bounds do not declare is an error at the definition
    /// (opaque_param_ops.k).
    fn checked_param(self, t: unsafe *Type) -> unsafe *Declarations::GenericParamDecl {
        return self._checked_param(t, false)
    }

    /// checked_param with a `derives`-bounded parameter included: the
    /// regime of its OPERATORS (binary, unary, compound, `^^`, the `==` of
    /// `===`). Those are looked up in Substitution::bound_scopes -- the bases' tables
    /// beside the interfaces' -- so a base that declares the operator binds
    /// it, and an operator no bound declares is the bound error at the
    /// definition rather than a deferral to clang.
    fn op_checked_param(self, t: unsafe *Type) -> unsafe *Declarations::GenericParamDecl {
        return self._checked_param(t, true)
    }

    priv fn _checked_param(self,
                           t:          unsafe *Type,
                           with_bases: bool) -> unsafe *Declarations::GenericParamDecl {
        var unsafe *c = canon_unqual(t)
        if c == &null || !isa<Types::GenericParamType>(c) {
            return &null
        }

        var unsafe *g = cast<Types::GenericParamType>(c)
        if g->owner == &null {
            return &null
        }

        var gps = decl_generic_params(g->owner)
        if (g->param_index as usize) >= gps.size() {
            return &null
        }

        var unsafe *gp = gps[g->param_index as usize]
        if gp == &null || gp->kind_bound == Declarations::GenericParamKindBound::Duck {
            return &null
        }

        if with_bases {
            return gp
        }

        var it = self.sc->bounds.find(g->owner as usize as u64)
        if it == self.sc->bounds.end() {
            return gp
        }

        var *_set = &it->second
        for var i: usize = 0; i < _set->derives_constraints.size(); ++i {
            var unsafe *k  = _set->derives_constraints[i]
            var unsafe *id = dyn_cast<NamedIdentExpr>(k->lhs)
            if id != &null && id->resolved_decl == gp {
                return &null
            }
        }

        return gp
    }

    /// checked_param, for any dependent head a body may use only through
    /// its bounds (Compiler/Spec/Generics.md#decisions): a checked parameter's declaration, or an
    /// associated type's requirement. An associated type is always checked:
    /// no `: type` regime reaches one (on a `: type` T, `T::Item` never
    /// forms). Null for anything else. Operators, conversions, formatting,
    /// null tests and patterns ask this, so `a == b` on `a: T::Item` is its
    /// bounds' `op ==` or an error, exactly as on a `T`.
    fn checked_head(self, t: unsafe *Type) -> unsafe *Decl {
        var unsafe *c = canon_unqual(t)
        if c != &null && isa<AssocType>(c) {
            return cast<AssocType>(c)->assoc
        }

        return unsafe (self.checked_param(t) as unsafe *Decl)
    }

    /// checked_head for an OPERATOR: op_checked_param's regime (a
    /// `derives`-bounded parameter included, its bases' operators being in
    /// Substitution::bound_scopes) for a parameter, and an associated type
    /// as checked_head has it. ONE rule for every dependent head: its
    /// operators are its interface bounds' requirements, then its bases'
    /// members, or the bound error at the definition.
    fn op_checked_head(self, t: unsafe *Type) -> unsafe *Decl {
        var unsafe *c = canon_unqual(t)
        if c != &null && isa<AssocType>(c) {
            return cast<AssocType>(c)->assoc
        }

        return unsafe (self.op_checked_param(t) as unsafe *Decl)
    }

    /// How a diagnostic names checked head \p t: `T`, or `T::Item`.
    fn head_spelling(self, t: unsafe *Type) -> string {
        var unsafe *c = canon_unqual(t)
        if c != &null && isa<AssocType>(c) {
            return self.str(c)
        }

        var unsafe *gp = self.op_checked_param(t)
        if gp != &null {
            return self.decl_name(unsafe (gp as unsafe *Decl))
        }

        return self.str(t)
    }

    /// The interface instance an AssocType for requirement \p td carries
    /// when it is named through \p through (a bound, or the Self of the
    /// interface it is named in): its DECLARING interface, so one entity has
    /// one canonical however it was reached -- `G::Node` through `G impl
    /// Big`, `Big derives Graph`, and Graph's `first() -> Self::Node`
    /// through the same G are the same type. \p through itself when it is
    /// the declaring interface (its arguments are then exact); the plain
    /// record of a non-generic declaring interface; null for one inherited
    /// from a GENERIC interface, whose arguments as seen from \p through
    /// are not computed (SC116E at the use).
    fn assoc_iface(self, through: unsafe *Type, td: unsafe *Decl) -> unsafe *Type {
        if through == &null || td == &null || td->semantic_dc == &null {
            return &null
        }

        var unsafe *home = (td->semantic_dc)->owner_decl()
        if home == &null || !isa<Declarations::InterfaceDecl>(home) {
            return &null
        }

        home = NameLookup::representative(home)
        var unsafe *td0 = self.record_decl(canon_unqual(through))
        if td0 != &null && NameLookup::representative(self.pattern_of(td0)) == home {
            return canon_unqual(through)
        }

        if decl_generic_params(home).size() > 0 {
            return &null
        }

        var none = cxx::std::vector<unsafe *Type>()
        return self.sc->types->record(home, unsafe &none)
    }

    /// The `impl` conjuncts of clause \p e, in clause order.
    fn impl_conjuncts(self, e: unsafe *Expr, @inout out: cxx::std::vector<unsafe *ConstraintExpr>) {
        var cs = cxx::std::vector<unsafe *ConstraintExpr>()
        self._conjuncts(e, unsafe &cs)
        for var i: usize = 0; i < cs.size(); ++i {
            if !cs[i]->is_derives() {
                out.push_back(cs[i])
            }
        }
    }

    /// Associated type \p ta's OWN `impl` bounds (`type Item impl Display`),
    /// in clause order. A generic one's clause also holds its parameters'
    /// (`type <K impl Hashable> Map`, hoisted as `K impl Hashable`), which
    /// bound K, not the type.
    fn assoc_own_bounds(self,
                        ta:         unsafe *Declarations::TypeAliasDecl,
                        @inout out: cxx::std::vector<unsafe *ConstraintExpr>) {
        var cs = cxx::std::vector<unsafe *ConstraintExpr>()
        self.impl_conjuncts(ta->requires_clause, &cs)
        for var i: usize = 0; i < cs.size(); ++i {
            if self._assoc_param_index(ta, cs[i]) == usize::MAX {
                out.push_back(cs[i])
            }
        }
    }

    /// The `impl` bounds of generic associated type \p ta's parameter \p k.
    fn assoc_param_bounds(self,
                          ta:         unsafe *Declarations::TypeAliasDecl,
                          k:          usize,
                          @inout out: cxx::std::vector<unsafe *ConstraintExpr>) {
        var cs = cxx::std::vector<unsafe *ConstraintExpr>()
        self.impl_conjuncts(ta->requires_clause, &cs)
        for var i: usize = 0; i < cs.size(); ++i {
            if self._assoc_param_index(ta, cs[i]) == k {
                out.push_back(cs[i])
            }
        }
    }

    /// Which of \p ta's own generic parameters conjunct \p c constrains, or
    /// usize(-1) for one about \p ta itself.
    priv fn _assoc_param_index(self,
                               ta: unsafe *Declarations::TypeAliasDecl,
                               c:  unsafe *ConstraintExpr) -> usize {
        var unsafe *id = dyn_cast<NamedIdentExpr>(c->lhs)
        if id == &null || id->resolved_decl == &null {
            return usize::MAX
        }

        for var k: usize = 0; k < ta->generic_params.size(); ++k {
            if *ta->generic_params.get(k) == id->resolved_decl {
                return k
            }
        }

        return usize::MAX
    }

    priv fn _conjuncts(self,
                       e:   unsafe *Expr,
                       out: unsafe *cxx::std::vector<unsafe *ConstraintExpr>) {
        if e == &null {
            return
        }

        if e->kind == ExprKind::BinaryOperatorExpr {
            var unsafe *b = cast<BinaryOperatorExpr>(e)
            if b->op_token.kind == TokenKind::OpAmpAmp || b->op_token.kind == TokenKind::KwAnd {
                self._conjuncts(b->lhs, out)
                self._conjuncts(b->rhs, out)
            }

            return
        }

        if e->kind == ExprKind::ConstraintExpr {
            out->push_back(cast<ConstraintExpr>(e))
        }
    }

    fn record_args(self, t: unsafe *Type) -> FrozenList<unsafe *Type> {
        var unsafe *u = canon_unqual(t)
        if u == &null || !isa<RecordType>(u) {
            return create_empty_frozen_list<unsafe *Type>()
        }

        return cast<RecordType>(u)->args
    }

    /// `[T; N]` only -- the one container that is still structural. Vector,
    /// HashSet and Slice are lang records; their element comes out of
    /// container_elem, off the record's arguments.
    fn element_of(self, t: unsafe *Type) -> unsafe *Type {
        var unsafe *u = canon_unqual(t)
        if u == &null {
            return &null
        }

        if isa<Types::FixedArrayType>(u) {
            return cast<Types::FixedArrayType>(u)->element
        }

        return &null
    }

    fn is_type_decl(self, d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        match d->kind {
            case DeclKind::ClassDecl {
                return true
            } case DeclKind::StructDecl {
                return true
            } case DeclKind::UnionDecl {
                return true
            } case DeclKind::EnumDecl {
                return true
            } case DeclKind::InterfaceDecl {
                return true
            } case DeclKind::TypeAliasDecl {
                return true
            } default {
                return false
            }
        }
    }

    fn is_record_decl(self, d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        match d->kind {
            case DeclKind::ClassDecl {
                return true
            } case DeclKind::StructDecl {
                return true
            } case DeclKind::UnionDecl {
                return true
            } case DeclKind::EnumDecl {
                return true
            } case DeclKind::InterfaceDecl {
                return true
            } default {
                return false
            }
        }
    }

    /// # decl helpers

    fn generic_params_of(self,
                         d: unsafe *Decl) -> FrozenList<unsafe *Declarations::GenericParamDecl> {
        return decl_generic_params(d)
    }

    /// The pattern a record decl is an instance of, or the decl itself.
    fn pattern_of(self, d: unsafe *Decl) -> unsafe *Decl {
        return decl_pattern(d)
    }

    /// Spelled with the decl's OWN context (hard invariant #2).
    fn decl_name(self, d: unsafe *Decl) -> string {
        if d == &null {
            return "<null>"
        }

        var unsafe *ctx = NameLookup::ctx_of(d)
        if ctx == &null {
            ctx = self.sc->ctx
        }

        if isa<Declarations::ClassDecl>(d) {
            return ctx->get_spelling(cast<Declarations::ClassDecl>(d)->name)
        }

        if isa<Declarations::StructDecl>(d) {
            return ctx->get_spelling(cast<Declarations::StructDecl>(d)->name)
        }

        if isa<Declarations::UnionDecl>(d) {
            return ctx->get_spelling(cast<Declarations::UnionDecl>(d)->name)
        }

        if isa<Declarations::InterfaceDecl>(d) {
            return ctx->get_spelling(cast<Declarations::InterfaceDecl>(d)->name)
        }

        if isa<Declarations::EnumDecl>(d) {
            return ctx->get_spelling(cast<Declarations::EnumDecl>(d)->name)
        }

        if isa<Declarations::TypeAliasDecl>(d) {
            return ctx->get_spelling(cast<Declarations::TypeAliasDecl>(d)->name)
        }

        if isa<Declarations::ModuleDecl>(d) {
            return ctx->get_spelling(cast<Declarations::ModuleDecl>(d)->name)
        }

        // An operator has no name token to spell (TokenText::resolve asserts
        // on its empty one); EvalUsageChecking named every `eval fn op ==`
        // through here and aborted the compile.
        if isa<Declarations::FunctionDecl>(d) && cast<Declarations::FunctionDecl>(d)->is_operator {
            return "op " + OperatorFacts::symbol(cast<Declarations::FunctionDecl>(d))
        }

        if isa<Declarations::FunctionDecl>(d) {
            return ctx->get_spelling(cast<Declarations::FunctionDecl>(d)->name)
        }

        if isa<Declarations::ParamDecl>(d) {
            return ctx->get_spelling(cast<Declarations::ParamDecl>(d)->name)
        }

        if isa<Declarations::VariableDecl>(d) {
            return ctx->get_spelling(cast<Declarations::VariableDecl>(d)->name)
        }

        if isa<Declarations::FieldDecl>(d) {
            return ctx->get_spelling(cast<Declarations::FieldDecl>(d)->name)
        }

        if isa<Declarations::EnumVariantDecl>(d) {
            return ctx->get_spelling(cast<Declarations::EnumVariantDecl>(d)->name)
        }

        if isa<Declarations::GenericParamDecl>(d) {
            return ctx->get_spelling(cast<Declarations::GenericParamDecl>(d)->name)
        }

        return "<decl>"
    }

    /// Spelling of a param name in the param's own interner.
    fn param_name(self, p: unsafe *Declarations::ParamDecl) -> string {
        var unsafe *ctx = NameLookup::ctx_of(unsafe (p as unsafe *Decl))
        if ctx == &null {
            ctx = self.sc->ctx
        }

        return ctx->get_spelling(p->name)
    }

    fn fid_of(self, d: unsafe *Decl) -> u32 {
        var unsafe *c = NameLookup::ctx_of(d)
        if c == &null {
            return self.sc->ctx->fid
        }

        return c->fid
    }

    fn is_foreign(self, d: unsafe *Decl) -> bool {
        var unsafe *c = NameLookup::ctx_of(d)
        return c != &null && c != self.sc->ctx
    }

    /// # inheritance
    ///
    /// Derived-to-base is Substitution::derives_from: it is a question about
    /// TYPES, since an instance's bases are its pattern's read through its
    /// arguments, and the substitution that reads them sits above this file.

    /// The first pure virtual method (FnBodyKind::Virtual: a bodyless
    /// `virtual fn`, or an imported C++ `= 0`) that `d` or one of its bases
    /// declares and nothing between it and `d` overrides; null when `d` is
    /// not abstract. A derived class that overrides some but not all of its
    /// base's pure methods stays abstract, as in C++. An override is matched
    /// by name and arity: overload resolution on the receiver is not this
    /// question's, and two same-named, same-arity methods in one chain are
    /// an override in practice (C++ would make a differing one a hide).
    fn first_pure_left(self, d: unsafe *Decl) -> unsafe *Declarations::FunctionDecl {
        if d == &null {
            return &null
        }

        var chain  = cxx::std::vector<unsafe *Decl>()
        var depths = cxx::std::vector<u32>()
        self._chain_walk(NameLookup::representative(d), unsafe &chain, unsafe &depths, 0)
        for var i: usize = 0; i < chain.size(); ++i {
            var unsafe *cd = dyn_cast<Declarations::ClassDecl>(chain[i])
            if cd == &null {
                continue
            }

            for var j: usize = 0; j < cd->methods.size(); ++j {
                var unsafe *p = cd->methods[j]
                if p == &null || p->body_kind != Declarations::FnBodyKind::Virtual {
                    continue
                }

                if !self._overridden_below(p, chain, depths, depths[i]) {
                    return p
                }
            }
        }

        return &null
    }

    priv fn _overridden_below(self,
                              p:            unsafe *Declarations::FunctionDecl,
                              const chain:  cxx::std::vector<unsafe *Decl>,
                              const depths: cxx::std::vector<u32>,
                              depth:        u32) -> bool {
        var pname = self.decl_name(unsafe (p as unsafe *Decl))
        for var i: usize = 0; i < chain.size(); ++i {
            if (depths)[i] >= depth {
                continue
            }

            var unsafe *cd = dyn_cast<Declarations::ClassDecl>((chain)[i])
            if cd == &null {
                continue
            }

            for var j: usize = 0; j < cd->methods.size(); ++j {
                var unsafe *m = cd->methods[j]
                if m == &null || m->body_kind == Declarations::FnBodyKind::Virtual {
                    continue
                }

                if m->params.size() != p->params.size() {
                    continue
                }

                if self.decl_name(unsafe (m as unsafe *Decl)) == pname {
                    return true
                }
            }
        }

        return false
    }

    priv fn _chain_walk(self,
                        d:      unsafe *Decl,
                        out:    unsafe *cxx::std::vector<unsafe *Decl>,
                        depths: unsafe *cxx::std::vector<u32>,
                        depth:  u32) {
        if depth > 64 {
            return
        }

        for var i: usize = 0; i < out->size(); ++i {
            if (*out)[i] == d {
                return
            }
        }

        out->push_back(d)
        depths->push_back(depth)
        var unsafe *cd = dyn_cast<Declarations::ClassDecl>(d)
        if cd == &null {
            return
        }

        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var unsafe *e = cd->derives_list.get(i)
            if e == &null || e->base == &null {
                continue
            }

            var unsafe *bd = self.record_decl(e->base->canonical)
            if bd != &null {
                self._chain_walk(NameLookup::representative(bd), out, depths, depth + 1)
            }
        }

        // an instance's methods and bases are its pattern's.
        var unsafe *pat = self.pattern_of(d)
        if pat != d {
            self._chain_walk(pat, out, depths, depth)
        }
    }

    /// Any virtual/override/pure method here or in a base: a vtable exists.
    fn is_polymorphic(self, d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        var seen = cxx::std::vector<unsafe *Decl>()
        return self._poly_walk(NameLookup::representative(d), unsafe &seen, 0)
    }

    priv fn _poly_walk(self,
                       d:     unsafe *Decl,
                       seen:  unsafe *cxx::std::vector<unsafe *Decl>,
                       depth: u32) -> bool {
        if depth > 64 {
            return false
        }

        for var i: usize = 0; i < seen->size(); ++i {
            if (*seen)[i] == d {
                return false
            }
        }

        seen->push_back(d)
        var unsafe *cd = dyn_cast<Declarations::ClassDecl>(d)
        if cd == &null {
            return false
        }

        for var i: usize = 0; i < cd->methods.size(); ++i {
            var unsafe *m = cd->methods[i]
            if m == &null {
                continue
            }

            if m->abi == Declarations::AbiKind::Virtual
                || m->abi == Declarations::AbiKind::Override {
                return true
            }

            if m->body_kind == Declarations::FnBodyKind::Virtual {
                return true
            }
        }

        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var unsafe *e = cd->derives_list.get(i)
            if e == &null || e->base == &null {
                continue
            }

            var unsafe *bd = self.record_decl(e->base->canonical)
            if bd != &null && self._poly_walk(NameLookup::representative(bd), seen, depth + 1) {
                return true
            }
        }

        var unsafe *pat = self.pattern_of(d)
        if pat != d {
            return self._poly_walk(pat, seen, depth + 1)
        }

        return false
    }

    /// # lang items

    /// `record(lang item decl, args)` or null when the item is unbound.
    /// SemaContext owns the builder: TypeResolve reaches the same one, so a
    /// written `[T;]` and one a literal takes share an identity AND a registry
    /// entry (without which the instance has no home TU and its bodies are
    /// emitted nowhere).
    fn lang_record(self,
                   k:    WellKnownType,
                   args: unsafe *cxx::std::vector<unsafe *Type>) -> unsafe *Type {
        return self.sc->lang_record(k, args)
    }

    /// A container canonical is the lang RECORD or nothing. There is no
    /// structural fallback: two spellings of one written type would be two
    /// identities, and null is the poisoned-component answer every caller
    /// already handles.
    fn vector_of(self, elem: unsafe *Type) -> unsafe *Type {
        if elem == &null {
            return &null
        }

        var a = cxx::std::vector<unsafe *Type>()
        a.push_back(elem)
        return self.lang_record(WellKnownType::Vector, unsafe &a)
    }

    fn slice_of(self, elem: unsafe *Type) -> unsafe *Type {
        if elem == &null {
            return &null
        }

        var a = cxx::std::vector<unsafe *Type>()
        a.push_back(elem)
        return self.lang_record(WellKnownType::Slice, unsafe &a)
    }

    /// The slice an array is viewed as: `[T; N]` -> `[T;]`, and a const
    /// array -> `[const T;]` so the view keeps the qualifier. Null for
    /// anything that is not an array, or with no Slice lang item.
    fn array_view(self, t: unsafe *Type) -> unsafe *Type {
        var unsafe *elem = self.element_of(t)
        if elem == &null {
            return &null
        }

        if canon_has_const(t) && !canon_has_const(elem) {
            elem = self.sc->types->qualified(elem, QUAL_CONST)
        }

        return self.slice_of(elem)
    }

    fn set_of(self, elem: unsafe *Type) -> unsafe *Type {
        if elem == &null {
            return &null
        }

        var a = cxx::std::vector<unsafe *Type>()
        a.push_back(elem)
        return self.lang_record(WellKnownType::HashSet, unsafe &a)
    }

    fn map_of(self, k: unsafe *Type, v: unsafe *Type) -> unsafe *Type {
        if k == &null || v == &null {
            return &null
        }

        var a = cxx::std::vector<unsafe *Type>()
        a.push_back(k)
        a.push_back(v)
        return self.lang_record(WellKnownType::HashMap, unsafe &a)
    }

    fn string_type(self) -> unsafe *Type {
        var a = cxx::std::vector<unsafe *Type>()
        return self.lang_record(WellKnownType::String, unsafe &a)
    }

    /// Is \p t the vector/set/map/string lang record, or its structural form.
    fn is_lang(self, t: unsafe *Type, k: WellKnownType) -> bool {
        var unsafe *d = self.sc->well_known->get(k)
        if d == &null {
            return false
        }

        var unsafe *rd = self.record_decl(t)
        if rd == &null {
            return false
        }

        return self.pattern_of(rd) == NameLookup::representative(d)
    }

    /// A generator's declared return: `-> yield T`, as WRITTEN (the
    /// qualifier is not on the canonical). It types each yielded value.
    /// A spelled-out `-> Yield<T>` is NOT one: it is an ordinary record
    /// return, which the coroutine machinery itself relies on
    /// (`get_return_object` returns a Yield<T> by value).
    fn is_generator_return(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        return t->is_yield()
    }

    fn is_vector_like(self, t: unsafe *Type) -> bool {
        return self.is_lang(t, WellKnownType::Vector)
    }

    fn is_map_like(self, t: unsafe *Type) -> bool {
        return self.is_lang(t, WellKnownType::HashMap)
    }

    fn is_set_like(self, t: unsafe *Type) -> bool {
        return self.is_lang(t, WellKnownType::HashSet)
    }

    fn is_slice(self, t: unsafe *Type) -> bool {
        return self.is_lang(t, WellKnownType::Slice)
    }

    fn is_string(self, t: unsafe *Type) -> bool {
        return self.is_lang(t, WellKnownType::String)
    }

    /// \p t is a C string parameter a literal's static bytes may stand for:
    /// a pointer of either kind to `const c_char` (C's `const
    /// char *`) or `const u8`. Const only: the bytes are a C++ literal in
    /// read-only storage, so a `char *` that may be written is refused.
    fn is_c_string_param(self, t: unsafe *Type) -> bool {
        // A C++ template member's `const T&` / `T&&` with T = `const char *`
        // (vector<const char*>::push_back) is the same slot: the literal
        // decays to a pointer temporary the reference binds. A non-const
        // lvalue reference cannot bind that temporary, as in C++.
        var unsafe *u = t
        if u != &null && isa<Types::CXXLValueRefType>(u) {
            u = cast<Types::CXXLValueRefType>(u)->referee
            if !canon_has_const(u) {
                return false
            }
        } else if u != &null && isa<Types::CXXRValueRefType>(u) {
            u = cast<Types::CXXRValueRefType>(u)->referee
        }

        var unsafe *p = self.pointee(u)
        if p == &null || !canon_has_const(p) {
            return false
        }

        var k = self.kind_of(canon_unqual(p))
        return k == BuiltinKind::CChar || k == BuiltinKind::U8
    }

    /// \p e as written is a plain string literal (not an f-string, which
    /// is built at run time): what a C string parameter of an imported
    /// function takes without a `string` being made. The bare
    /// literal only; a parenthesized one stays a `string`.
    fn c_string_literal(self, e: unsafe *Expr) -> unsafe *StringLiteralExpr {
        if e == &null || e->is_poisoned() || !isa<StringLiteralExpr>(e) {
            return &null
        }

        var unsafe *s = cast<StringLiteralExpr>(e)
        if s->is_format() {
            return &null
        }

        return s
    }

    /// # tuples
    ///
    /// `(A, B, ..)` is the record `TupleN<A, B, ..>` (TupleRecords): no
    /// canonical is a TupleType after T. Tuple-ness is the pattern's
    /// `tuple_arity`, by identity -- a user's own `Tuple2` is not one.

    /// The tuple record decl \p d is (its pattern has an arity), else false.
    fn is_tuple_decl(self, d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        var unsafe *s = dyn_cast<Declarations::StructDecl>(
            self.pattern_of(NameLookup::representative(d)),
        )

        return s != &null && s->tuple_arity > 0
    }

    /// The arity of a tuple canonical, 0 for anything else.
    fn tuple_arity(self, t: unsafe *Type) -> usize {
        var unsafe *d = self.record_decl(t)
        if d == &null {
            return 0
        }

        var unsafe *s = dyn_cast<Declarations::StructDecl>(
            self.pattern_of(NameLookup::representative(d)),
        )

        if s == &null {
            return 0
        }

        return s->tuple_arity as usize
    }

    fn is_tuple(self, t: unsafe *Type) -> bool {
        return self.tuple_arity(t) > 0
    }

    /// The element types of a tuple canonical: the record's arguments, in
    /// element order (the pattern's field `_i` is typed `Ti`, which is
    /// args[i] in the instance -- by construction, no substitution needed).
    fn tuple_elems(self, t: unsafe *Type) -> FrozenList<unsafe *Type> {
        return self.record_args(t)
    }

    /// `record(TupleN, elems)`, or null when there is no record for that
    /// arity (no builtin root, or past TUPLE_MAX_ARITY; the caller diagnoses
    /// -- TypeParse already rejects it at a written type).
    fn tuple_of(self, elems: unsafe *cxx::std::vector<unsafe *Type>) -> unsafe *Type {
        return self.sc->tuple_record(elems)
    }

    /// Field \p i of a tuple canonical, read off the PATTERN (an instance
    /// shell has no fields until M2); null when out of range.
    fn tuple_field(self, t: unsafe *Type, i: usize) -> unsafe *Declarations::FieldDecl {
        var unsafe *d = self.record_decl(t)
        if d == &null {
            return &null
        }

        var unsafe *s = dyn_cast<Declarations::StructDecl>(
            self.pattern_of(NameLookup::representative(d)),
        )

        if s == &null || s->tuple_arity == 0 || i >= s->fields.size() {
            return &null
        }

        return s->fields[i]
    }

    /// Element type of a vector/set/array/slice, whichever canonical form.
    fn container_elem(self, t: unsafe *Type) -> unsafe *Type {
        var unsafe *e = self.element_of(t)
        if e != &null {
            return e
        }

        if self.is_vector_like(t) || self.is_set_like(t) || self.is_slice(t) {
            var args = self.record_args(t)
            if args.size() > 0 {
                return args[0]
            }
        }

        return &null
    }

    fn map_key_value(self,
                     t: unsafe *Type,
                     k: unsafe *(unsafe *Type),
                     v: unsafe *(unsafe *Type)) -> bool {
        var unsafe *u = canon_unqual(t)
        if u == &null {
            return false
        }

        if self.is_lang(t, WellKnownType::HashMap) {
            var args = self.record_args(t)
            if args.size() >= 2 {
                *k = args[0]
                *v = args[1]
                return true
            }
        }

        return false
    }

    /// # calls

    /// The parameter at \p i across \p f's WHOLE redeclaration chain that
    /// specifies a default -- a Kairo expression, the thunk CallLowering made
    /// of one, or an imported C++ default -- or null. Defaults accumulate
    /// across a chain and RedeclMerge admits one per index, so no single link
    /// is authoritative and every reader asks here.
    fn param_default(self,
                     f: unsafe *Declarations::FunctionDecl,
                     i: usize) -> unsafe *Declarations::ParamDecl {
        if f == &null {
            return &null
        }

        var links = cxx::std::vector<unsafe *Decl>()
        NameLookup::collect_chain(f, &links)
        if links.size() == 0 {
            links.push_back(f)
        }

        for var k: usize = 0; k < links.size(); ++k {
            var unsafe *g = dyn_cast<Declarations::FunctionDecl>(links[k])
            if g == &null || i >= g->params.size() {
                continue
            }

            var unsafe *p = g->params[i]
            if p == &null {
                continue
            }

            if p->default_val != &null || p->default_thunk != &null || p->has_default {
                return p
            }
        }

        return &null
    }

    /// The type a USE of \p p has inside its function. A pack `...xs: T` is
    /// `[T;]` (Slice<T>, by value); every other parameter is its declared
    /// canonical. Null when the pack's element is dependent (a generic pack;
    /// not modelled yet) or the type never resolved. The declared `type_`
    /// stays the element: overload resolution ranks each pack argument
    /// against it, and CallLowering builds the slice from it.
    fn param_value_type(self, p: unsafe *Declarations::ParamDecl) -> unsafe *Type {
        if p == &null || p->type_ == &null || p->type_->canonical == &null {
            return &null
        }

        var unsafe *c = p->type_->canonical
        if !p->is_pack {
            return c
        }

        var unsafe *elem = canon_unqual(c)
        if elem == &null || elem->is_dependent() {
            return &null
        }

        return self.slice_of(elem)
    }

    /// \p p's index in \p f->params, `self` included; usize(-1) if absent.
    fn param_index(self,
                   f: unsafe *Declarations::FunctionDecl,
                   p: unsafe *Declarations::ParamDecl) -> usize {
        for var i: usize = 0; i < f->params.size(); ++i {
            if f->params[i] == p {
                return i
            }
        }

        return usize::MAX
    }

    /// A lang record's constructor BY SHAPE: \p nparams non-self parameters,
    /// and for \p from_slice the single one is a Slice. Found through the lang
    /// item, never by name. LiteralTyping binds literals through it and
    /// CallLowering binds a pack's slice through it: one lookup, one answer.
    fn lang_ctor(self, k: WellKnownType, nparams: usize, from_slice: bool) -> unsafe *Decl {
        var unsafe *d = self.sc->well_known->get(k)
        if d == &null {
            return &null
        }

        var unsafe *body = self.pattern_of(NameLookup::representative(d))
        var unsafe *dc   = NameLookup::context_of(body)
        if dc == &null {
            return &null
        }

        var cell = self.sc->lookup.in_context(dc, DeclName::ctor())
        if !cell.found() {
            return &null
        }

        for var i: usize = 0; i < cell.cell->size(); ++i {
            var unsafe *f = dyn_cast<Declarations::FunctionDecl>(cell.cell->get(i))
            if f == &null {
                continue
            }

            var n:    usize                           = 0
            var only: unsafe *Declarations::ParamDecl = &null
            for var p: usize = 0; p < f->params.size(); ++p {
                var unsafe *pd = f->params[p]
                if pd == &null || pd->is_self {
                    continue
                }

                n += 1
                only = pd
            }

            if n != nparams {
                continue
            }

            if from_slice {
                if only == &null || only->type_ == &null || !self.is_slice(only->type_->canonical) {
                    continue
                }
            }

            return cell.cell->get(i)
        }

        return &null
    }

    /// # qualifiers

    fn quals(self, t: unsafe *Type) -> u8 {
        return canon_quals(t)
    }

    fn unqual(self, t: unsafe *Type) -> unsafe *Type {
        return canon_unqual(t)
    }

    fn has_const(self, t: unsafe *Type) -> bool {
        return canon_has_const(t)
    }

    fn has_volatile(self, t: unsafe *Type) -> bool {
        return canon_has_volatile(t)
    }

    /// # syntax quals
    ///
    /// Quals are excluded from canonicals by design; these read the SYNTAX
    /// node, through the TypeQual mixin every Type derives (AST/Mixin/
    /// TypeQual.k) rather than through the parser's PendingQuals accumulator,
    /// which is not visible from Sema.

    fn syntax_is_const(self, t: *Type?) -> bool {
        if t == &null {
            return false
        }

        return t->is_const()
    }

    fn syntax_is_unsafe(self, t: *Type?) -> bool {
        if t == &null {
            return false
        }

        return t->is_unsafe()
    }

    /// # default values

    /// Empty when a value of \p t can be built from nothing; otherwise why
    /// not, phrased to follow "and" ("'x' is declared without an
    /// initializer, and ..."). variables.mdx: a number or a pointer is 0 /
    /// null, a nullable is null, a record with a usable constructor callable
    /// on `self` alone is that, an array is its elements'. `bool` has no zero
    /// state to assume, a record without such a constructor -- none at all,
    /// or one deleted -- is never built, and an enum with payloads has no
    /// variant to pick. Imported C++ types and dependent ones answer empty:
    /// clang and instantiation decide them. One answer for every binding
    /// that has no initializer: a local, a static (InitCheck) and a field a
    /// constructor must build (CtorInitCheck).
    fn why_no_default(self, t: unsafe *Type) -> string {
        return self._why_no_default(t, 0)
    }

    /// \p depth bounds the walk into fields: a by-value cycle is
    /// TypeCycleCheck's error, but this question may be asked before it
    /// poisons the cycle, and must not recurse forever meanwhile.
    priv fn _why_no_default(self, t: unsafe *Type, depth: u32) -> string {
        if depth > 16 {
            return ""
        }

        var unsafe *el = self.element_of(t)
        if el != &null {
            return self._why_no_default(canon_unqual(el), depth + 1)
        }

        if self.is_bool(t) {
            return "'bool' has no zero state: a default would have to guess true or false"
        }

        if self.nullable_inner(t) != &null {
            return ""
        }

        var unsafe *en = self.payload_enum(t)
        if en != &null {
            var en_nm = self.sc->ctx->get_spelling(en->name)
            return f"'{en_nm}' is an enum with payloads, so no variant is its default"
        }

        var unsafe *rd = self.default_record(t)
        if rd == &null {
            return ""
        }

        var nm = self.decl_name(rd)
        if decl_only_forward(rd) {
            return f"'{nm}' is only forward-declared, so there is nothing to build"
        }

        var unsafe *dc = self.default_ctor_of(rd)
        if dc == &null && !self.declares_ctor(rd) {
            return self._why_no_implicit(rd, depth)
        }

        if dc == &null {
            return f"'{nm}' has no default constructor (declare 'fn {nm}(self)')"
        }

        if dc->body_kind == Declarations::FnBodyKind::Delete {
            return f"the default constructor of '{nm}' is deleted"
        }

        return ""
    }

    /// A record that declares no constructor has the implicit default one
    /// (interfaces-requirements.mdx: "A type that declares no constructor at
    /// all has the implicit one"), and it builds every base and field from
    /// nothing, so it exists exactly when each of them can be: a field with
    /// an initializer, or whose type has a default. A `const` field without
    /// an initializer cannot (a constructor must give it its one value,
    /// classes.mdx), nor can a C++ value-initialization of one. Empty when
    /// it exists; otherwise why not, naming the first base or field that
    /// stops it. A dependent field (`var v: T`) answers empty, as every
    /// dependent type does: the instance decides.
    priv fn _why_no_implicit(self, rd: unsafe *Decl, depth: u32) -> string {
        var nm = self.decl_name(rd)
        if isa<Declarations::ClassDecl>(rd) {
            var *bases = &cast<Declarations::ClassDecl>(rd)->derives_list
            for var i: usize = 0; i < bases->size(); ++i {
                var unsafe *e = bases->get(i)
                if e == &null || e->base == &null || e->base->canonical == &null {
                    continue
                }

                var bw = self._why_no_default(canon_unqual(e->base->canonical), depth + 1)
                if !bw.empty() {
                    return f"'{nm}' has no default constructor: the implicit one cannot build its base ({bw})"
                }
            }
        }

        var *fs = if (isa<Declarations::ClassDecl>(rd)) => (&cast<Declarations::ClassDecl>(
                      rd,
                  )->fields)
                  else => &cast<Declarations::StructDecl>(rd)->fields
        for var i: usize = 0; i < fs->size(); ++i {
            var unsafe *f = (*fs)[i]
            if f == &null || f->is_anonymous_union {
                continue
            }

            if f->storage == Declarations::StorageClass::Static
                || f->storage == Declarations::StorageClass::Eval {
                continue
            }

            if f->init != &null
                || f->init_thunk != &null
                || f->init_fold != Declarations::FieldFold::None {
                continue
            }

            var fnm = self.sc->ctx->get_spelling(f->name)
            if f->storage == Declarations::StorageClass::Const {
                return f"'{nm}' has no default constructor: the implicit one cannot give const field '{fnm}' a value, and it has no initializer"
            }

            if f->type_ == &null || f->type_->canonical == &null {
                continue
            }

            var fw = self._why_no_default(canon_unqual(f->type_->canonical), depth + 1)
            if !fw.empty() {
                return f"'{nm}' has no default constructor: the implicit one cannot build field '{fnm}', which has no initializer ({fw})"
            }
        }

        return ""
    }

    /// \p d (class or struct) declares a constructor of any kind: one named
    /// after it, a transfer (`@copy` / `@move`) included, deleted included.
    /// Any of them suppresses the implicit default constructor, as a
    /// user-declared constructor of any kind does in C++ -- which is what
    /// the emitted class has to agree with.
    fn declares_ctor(self, d: unsafe *Decl) -> bool {
        var nm = self.decl_name(d)
        var ms = if (isa<Declarations::ClassDecl>(d)) => (cast<Declarations::ClassDecl>(d)->methods)
                 else => cast<Declarations::StructDecl>(d)->methods
        for var i: usize = 0; i < ms.size(); ++i {
            var unsafe *m = ms[i]
            if m == &null || m->is_operator || m->adt_role != Declarations::AdtRole::None {
                continue
            }

            if self.decl_name(m) == nm {
                return true
            }
        }

        return false
    }

    /// The Kairo enum with payloads \p t names (its pattern), else null.
    fn payload_enum(self, t: unsafe *Type) -> unsafe *Declarations::EnumDecl {
        var unsafe *rd = self.record_decl(t)
        if rd == &null {
            return &null
        }

        if decl_is_instance(rd) {
            rd = decl_pattern(rd)
        }

        if rd == &null || !isa<Declarations::EnumDecl>(rd) || decl_is_imported(rd) {
            return &null
        }

        var unsafe *en = cast<Declarations::EnumDecl>(rd)
        return if (en->is_adt) => (en) else => &null
    }

    /// A Kairo class or struct, pattern side, as the default-value question
    /// sees it. Null for an imported C++ record (clang decides), an enum, a
    /// dependent type.
    fn default_record(self, t: unsafe *Type) -> unsafe *Decl {
        var unsafe *rd = self.record_decl(t)
        if rd == &null {
            return &null
        }

        if decl_is_instance(rd) {
            rd = decl_pattern(rd)
        }

        if rd == &null || decl_is_imported(rd) {
            return &null
        }

        if (!isa<Declarations::ClassDecl>(rd)) && !isa<Declarations::StructDecl>(rd) {
            return &null
        }

        return rd
    }

    /// The constructor of class or struct \p d callable with no arguments:
    /// not an operator, not a transfer (`@copy`/`@move` build from another
    /// value, not from none), every parameter but `self` defaulted.
    fn default_ctor_of(self, d: unsafe *Decl) -> unsafe *Declarations::FunctionDecl {
        var nm = self.decl_name(d)
        var ms = if (isa<Declarations::ClassDecl>(d)) => (cast<Declarations::ClassDecl>(d)->methods)
                 else => cast<Declarations::StructDecl>(d)->methods
        for var i: usize = 0; i < ms.size(); ++i {
            var unsafe *m = ms[i]
            if m == &null || m->is_operator || m->adt_role != Declarations::AdtRole::None {
                continue
            }

            if m->transfer != Declarations::TransferKind::NotTransfer || self.decl_name(m) != nm {
                continue
            }

            var ok = true
            for var j: usize = 0; j < m->params.size(); ++j {
                var unsafe *p = m->params[j]
                if p->is_self {
                    continue
                }

                if p->default_val == &null && !p->has_default && !p->is_pack {
                    ok = false
                    break
                }
            }

            if ok {
                return m
            }
        }

        return &null
    }

    /// The list literal an array field is initialized with, when
    /// FieldInitLowering lowers it one leaf element at a time (a thunk
    /// each): an instance or static field, its element an array again
    /// (`[[i32; 2]; 2]`) as long as every nested element is a list literal
    /// too. Null for every other initializer: an eval field's (SC116E: its
    /// consteval definition waits on a single thunk, Compiler/Spec/Eval.md#eval-bindings), and one
    /// that copies an array (SC083E, reject_array_copy; the typer has
    /// already said so).
    fn array_field_list(self, f: unsafe *Declarations::FieldDecl) -> unsafe *ListLiteralExpr {
        if f == &null || f->init == &null || f->is_eval() || f->type_ == &null {
            return &null
        }

        var unsafe *c = canon_unqual(f->type_->canonical)
        if c == &null || !isa<Types::FixedArrayType>(c) {
            return &null
        }

        var unsafe *e = self.strip_parens(f->init)
        if e == &null || !isa<ListLiteralExpr>(e) {
            return &null
        }

        if !self._nested_lists(cast<ListLiteralExpr>(e), c) {
            return &null
        }

        return cast<ListLiteralExpr>(e)
    }

    /// Every element of \p lit whose type \p at says is an array is a
    /// list literal of its own, to the innermost level.
    priv fn _nested_lists(self, lit: unsafe *ListLiteralExpr, at: unsafe *Type) -> bool {
        var unsafe *el = canon_unqual(cast<Types::FixedArrayType>(at)->element)
        if el == &null || !isa<Types::FixedArrayType>(el) {
            return true
        }

        for var i: usize = 0; i < lit->elements.size(); ++i {
            var unsafe *e = self.strip_parens(lit->elements[i])
            if e == &null || !isa<ListLiteralExpr>(e) {
                return false
            }

            if !self._nested_lists(cast<ListLiteralExpr>(e), el) {
                return false
            }
        }

        return true
    }

    /// The leaf elements of an array field's list literal (array_field_list
    /// said yes), in row-major order, appended to \p out; the innermost
    /// element type is the return.
    fn array_field_leaves(self,
                          lit: unsafe *ListLiteralExpr,
                          at:  unsafe *Type,
                          out: unsafe *cxx::std::vector<unsafe *Expr>) -> unsafe *Type {
        var unsafe *el = canon_unqual(cast<Types::FixedArrayType>(at)->element)
        if el == &null || !isa<Types::FixedArrayType>(el) {
            for var i: usize = 0; i < lit->elements.size(); ++i {
                out->push_back(lit->elements[i])
            }

            return cast<Types::FixedArrayType>(at)->element
        }

        var leaf: unsafe *Type = &null
        for var i: usize = 0; i < lit->elements.size(); ++i {
            leaf = self.array_field_leaves(
                cast<ListLiteralExpr>(self.strip_parens(lit->elements[i])),
                el,
                out,
            )
        }

        return leaf
    }

    /// Some list literal in \p e, an array initializer, or one nested in
    /// it, was rejected already (SC083E on a copied element, say): the
    /// typer has spoken, and no gate needs to.
    fn array_init_poisoned(self, e_in: unsafe *Expr) -> bool {
        var unsafe *e = self.strip_parens(e_in)
        if e == &null {
            return false
        }

        if e->is_poisoned() {
            return true
        }

        if !isa<ListLiteralExpr>(e) {
            return false
        }

        var unsafe *lit = cast<ListLiteralExpr>(e)
        for var i: usize = 0; i < lit->elements.size(); ++i {
            if self.array_init_poisoned(lit->elements[i]) {
                return true
            }
        }

        return false
    }

    /// # expr helpers

    fn strip_parens(self, e: unsafe *Expr) -> unsafe *Expr {
        var unsafe *x = e
        while x != &null && isa<ParenExpr>(x) {
            x = cast<ParenExpr>(x)->inner
        }

        return x
    }

    /// # rendering

    /// A computed value's binary operator, as written (TypeResolve keeps the
    /// symbol form).
    priv fn _value_op(self, k: TokenKind) -> string {
        if k == TokenKind::OpPlus {
            return "+"
        }

        if k == TokenKind::OpMinus {
            return "-"
        }

        if k == TokenKind::OpStar {
            return "*"
        }

        if k == TokenKind::OpSlash {
            return "/"
        }

        if k == TokenKind::OpPercent {
            return "%"
        }

        if k == TokenKind::OpPipe {
            return "|"
        }

        if k == TokenKind::OpAmp {
            return "&"
        }

        if k == TokenKind::OpCaret {
            return "^"
        }

        if k == TokenKind::OpLessLess {
            return "<<"
        }

        if k == TokenKind::OpGreaterGreater {
            return ">>"
        }

        return "?"
    }

    pub fn str(self, t: unsafe *Type) -> string {
        if t == &null {
            return "<unknown>"
        }

        match t->kind {
            case TypeKind::BuiltinType {
                return cast<BuiltinType>(t)->spelling()
            } case TypeKind::RecordType {
                // A lang container prints as the SUGAR it was written as:
                // `[i32]`, not `Vector<i32>`. Every diagnostic quotes this, so
                // the spelling a user sees is the one they typed.
                if self.is_slice(t) {
                    var sa = self.record_args(t)
                    if sa.size() > 0 {
                        return "[" + self.str(sa[0]) + ";]"
                    }
                }

                if self.is_vector_like(t) {
                    var va = self.record_args(t)
                    if va.size() > 0 {
                        return "[" + self.str(va[0]) + "]"
                    }
                }

                if self.is_set_like(t) {
                    var ea = self.record_args(t)
                    if ea.size() > 0 {
                        return "{" + self.str(ea[0]) + "}"
                    }
                }

                if self.is_map_like(t) {
                    var ma = self.record_args(t)
                    if ma.size() >= 2 {
                        return "{" + self.str(ma[0]) + ": " + self.str(ma[1]) + "}"
                    }
                }

                if self.is_string(t) {
                    return to_string(WellKnownType::String)
                }

                // A tuple prints as it is written, `(i32, f64)`: every
                // golden and every message that quotes one reads so.
                if self.is_tuple(t) {
                    var ta = self.record_args(t)
                    var s  = "("
                    for var i: usize = 0; i < ta.size(); ++i {
                        if i > 0 {
                            s += ", "
                        }

                        s += self.str(ta[i])
                    }

                    return s + ")"
                }

                var unsafe *r = cast<RecordType>(t)
                var        s  = self.decl_name(r->decl)
                // `L<i32>::P`: named through its enclosing instance.
                if r->outer != &null {
                    s = self.str(r->outer) + "::" + s
                }

                if r->args.size() > 0 {
                    s += "<"
                    for var i: usize = 0; i < r->args.size(); ++i {
                        if i > 0 {
                            s += ", "
                        }

                        s += self.str(r->args[i])
                    }

                    s += ">"
                }

                return s
            } case TypeKind::PointerType {
                var unsafe *p  = cast<Types::PointerType>(t)
                var        pre = if (p->is_unsafe) => ("unsafe *") else => "*"
                // `*T?` reads as a nullable pointer, so a pointer TO a
                // nullable is written the only way that parses back to it.
                if isa<Types::NullableType>(p->pointee) {
                    return pre + "(" + self.str(p->pointee) + ")"
                }

                return pre + self.str(p->pointee)
            }

            // `T??` is the `??` operator, so a nested nullable is written
            // the only way that parses back to it.
            case TypeKind::NullableType {
                var unsafe *inner = cast<Types::NullableType>(t)->inner
                if isa<Types::NullableType>(canon_unqual(inner)) {
                    return "(" + self.str(inner) + ")?"
                }

                return self.str(inner) + "?"
            } case TypeKind::VectorType {
                return "[" + self.str(cast<Types::VectorType>(t)->element) + "]"
            } case TypeKind::SetType {
                return "{" + self.str(cast<Types::SetType>(t)->element) + "}"
            } case TypeKind::MapType {
                var unsafe *m = cast<Types::MapType>(t)
                return "{" + self.str(m->key) + ": " + self.str(m->value) + "}"
            } case TypeKind::FixedArrayType {
                var unsafe *a = cast<Types::FixedArrayType>(t)
                if a->is_incomplete {
                    return "[" + self.str(a->element) + ";]"
                }

                if a->extent_param != &null {
                    return "[" + self.str(a->element) + "; " + self.str(a->extent_param) + "]"
                }

                return f"[{self.str(a->element)}; {a->size_bits}]"
            }

            // A generic VALUE argument (`4` of `Ring<4, i32>`).
            case TypeKind::TypeExpr {
                var unsafe *v = cast<Types::TypeExpr>(t)
                if !v->is_value {
                    return "<value>"
                }

                if v->is_exact() {
                    return if (v->vneg) => (f"-{v->vmag}") else => f"{v->vmag}"
                }

                // A computed value (Compiler/Spec/Eval.md#value-nodes), as Kairo would write it.
                match v->vop {
                    case Types::ValueOp::Decl {
                        return self.decl_name(v->vdecl)
                    } case Types::ValueOp::Call {
                        var s = self.decl_name(v->vdecl) + "("
                        for var i: usize = 0; i < v->vops.size(); ++i {
                            if i > 0 {
                                s += ", "
                            }

                            s += self.str(v->vops[i])
                        }

                        return s + ")"
                    } case Types::ValueOp::Unary {
                        return (if (v->vtok == TokenKind::OpTilde) => ("~") else => "-") + self.str(
                            v->vops[0],
                        )
                    } case Types::ValueOp::Binary {
                        return "(" + self.str(v->vops[0]) + " " + self._value_op(
                            v->vtok,
                        ) + " " + self.str(v->vops[1]) + ")"
                    } case Types::ValueOp::Cast {
                        return "(" + self.str(v->vops[0]) + " as " + self.str(v->vty) + ")"
                    } case Types::ValueOp::Str {
                        // The bytes as a literal: printable ASCII as is, the
                        // rest (and `"` / `\`) escaped as `\xNN`.
                        var digits = "0123456789abcdef"
                        var s      = "\""
                        for var i: usize = 0; i < (v->vmag as usize); ++i {
                            var b = v->vbytes[i]
                            if b >= (0x20 as u8)
                                && b < (0x7f as u8)
                                && b != (0x22 as u8)
                                && b != (0x5c as u8) {
                                s.push_back(b)
                                continue
                            }

                            s += "\\x"
                            s.push_back(digits[(b >> (4 as u8)) as usize])
                            s.push_back(digits[(b & (15 as u8)) as usize])
                        }

                        return s + "\""
                    } default {
                        return "<value>"
                    }
                }
            }

            // No TupleType arm: a tuple canonical is its record (above);
            // a syntax TupleType falls to the default and prints its canonical.
            case TypeKind::FunctionPointerType {
                var unsafe *f = cast<Types::FunctionPointerType>(t)
                // A convention implies raw, so its type is written without
                // `unsafe`: `fn (u64) @preserve_most -> u64`.
                var s = if (f->is_raw && f->call_conv == 0) => ("unsafe fn (") else => "fn ("
                for var i: usize = 0; i < f->params.size(); ++i {
                    if i > 0 {
                        s += ", "
                    }

                    // the mode is in the canonical, so it is in the spelling:
                    // `fn(@inout i32)` and `fn(i32)` must not render alike.
                    if i < f->modes.size() {
                        s += param_mode_prefix(f->modes[i])
                    }

                    s += self.str(f->params[i])
                }

                s += ")"
                if f->call_conv != 0 {
                    s += " @" + LangAttrs::call_conv_name(f->call_conv)
                }

                // The effect is part of the type: `fn () panic(E1, E2)`.
                if f->canon_panics {
                    s += " panic"
                    if f->panic_set.size() > 0 {
                        s += "("
                        for var i: usize = 0; i < f->panic_set.size(); ++i {
                            if i > 0 {
                                s += ", "
                            }

                            s += self.str(f->panic_set[i])
                        }

                        s += ")"
                    }
                }

                if f->return_type != &null && !self.is_void(f->return_type) {
                    s += " -> " + self.str(f->return_type)
                }

                return s
            } case TypeKind::GenericParamType {
                var unsafe *g  = cast<Types::GenericParamType>(t)
                var        gps = self.generic_params_of(g->owner)
                if g->owner != &null && (g->param_index as usize) < gps.size() {
                    var unsafe *gp = gps[g->param_index as usize]
                    if gp != &null {
                        return self.decl_name(unsafe (gp as unsafe *Decl))
                    }
                }

                return "<T>"
            }

            // The C++ spelling clang gave it (`std::FILE`, `__m128i`). A bare
            // "<ffi type>" told the user nothing, and two of them tied in
            // EffectPropagation's order, which then fell back to addresses.
            case TypeKind::OpaqueFFIType {
                var sp = cast<Types::OpaqueFFIType>(t)->text()
                if sp.length() == 0 {
                    return "<ffi type>"
                }

                return sp
            }

            // `T::Node`; `Self::Node` while the base is the interface's own
            // Self (it is then the interface record itself).
            case TypeKind::AssocType {
                var unsafe *a = cast<AssocType>(t)
                var        nm = self.decl_name(a->assoc)
                if a->args.size() > 0 {
                    nm += "<"
                    for var i: usize = 0; i < a->args.size(); ++i {
                        if i > 0 {
                            nm += ", "
                        }

                        nm += self.str(a->args[i])
                    }

                    nm += ">"
                }

                if a->base == a->iface {
                    return "Self::" + nm
                }

                return self.str(a->base) + "::" + nm
            } case TypeKind::QualifiedType {
                var unsafe *q = cast<QualifiedType>(t)
                var        s  = ""
                if (q->quals & QUAL_CONST) != 0 {
                    s += "const "
                }

                if (q->quals & QUAL_VOLATILE) != 0 {
                    s += "volatile "
                }

                return s + self.str(q->inner)
            } case TypeKind::CXXLValueRefType {
                return self.str(cast<Types::CXXLValueRefType>(t)->referee) + "&"
            } case TypeKind::CXXRValueRefType {
                return self.str(cast<Types::CXXRValueRefType>(t)->referee) + "&&"
            } case TypeKind::SelfType {
                return if (t->canonical != &null) => (self.str(t->canonical)) else => "Self"
            } default {
                if t->canonical != &null && t->canonical != t {
                    return self.str(t->canonical)
                }

                return "<type>"
            }
        }
    }
}
