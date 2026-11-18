/// --- The Kairo Project ------------------------- Sema/Type/TypeUtil.k --- ///
///
/// Read-only queries over canonical types and decls that every typer
/// mixin needs and that belong to none of them. A component held by
/// value on ExprTyper; no state beyond the SemaContext handle.
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
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::SymbolTable::DeclName
import AST::DeclFacts::{
    decl_fields,             decl_generic_params, decl_is_imported, decl_is_instance,
    decl_methods,            decl_only_forward,   decl_pattern,     decl_requires_clause,
    for_each_unwrapped_decl, param_is_type_pack,  peel_ref,
}
import AST::ExprFacts
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
import AST::Mixin::Annotation::VisibilityKind
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
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
    StringLiteralExpr,
}
import AST::Node::Statements
import AST::Node::Statements::IterYield
import AST::Node::Types
import AST::OperatorFacts::OperatorFacts
import AST::ParamMode::{
    ParamMode,
    param_mode_prefix,
}
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

/// The members a vector, set or map literal is built through when its
/// elements cannot be copied (TypeUtil::literal_build): the record's default
/// constructor, `reserve(n)` once, then one `add` per element -- `push(e)`
/// on a Vector, `insert(e)` on a HashSet, `insert(k, v)` on a HashMap. `add`
/// takes each operand by value, so the element is moved into the container;
/// it is null when the record declares no such member (one that takes the
/// element `const` copies it) or no default constructor, and the literal
/// cannot be built. `reserve` is null when the record has none, and is then
/// left out.
pub struct LiteralBuild {
    var ctor:    unsafe *Decl = &null
    var reserve: unsafe *Decl = &null
    var add:     unsafe *Decl = &null
}

/// Every leaf of requires clause `e`, in clause order: the operands of
/// its `&&` / `and` tree, to any depth. A leaf is a `T impl I` / `T derives
/// B` ConstraintExpr or a value predicate; a null clause has none.
pub fn conjuncts(e: unsafe *Expr, out: unsafe *cxx::std::vector<unsafe *Expr>) {
    if e == &null {
        return
    }

    var unsafe *b = dyn_cast<BinaryOperatorExpr>(e)
    if b != &null
        && (b->op_token.kind == TokenKind::OpAmpAmp || b->op_token.kind == TokenKind::KwAnd) {
        conjuncts(b->lhs, out)
        conjuncts(b->rhs, out)
        return
    }

    out->push_back(e)
}

/// The `impl` / `derives` leaves of requires clause `e` (conjuncts), in
/// clause order. False when `e` also has a value predicate; those are
/// left out of `out`.
pub fn constraint_conjuncts(e:   unsafe *Expr,
                            out: unsafe *cxx::std::vector<unsafe *ConstraintExpr>) -> bool {
    var leaves = cxx::std::vector<unsafe *Expr>()
    conjuncts(e, unsafe &leaves)
    var only = true
    for var i: usize = 0; i < leaves.size(); ++i {
        var unsafe *c = dyn_cast<ConstraintExpr>(leaves[i])
        if c == &null {
            only = false
            continue
        }

        out->push_back(c)
    }

    return only
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

    /// COUNT when `t` is not a builtin.
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

    /// The binder rule of what a generator yields (`y`, the `T` of
    /// `Yield<T>`): Pointer for `*T`, UnsafePointer for `unsafe *T`, Value
    /// for anything else (a nullable pointer `*T?` included).
    fn iter_yield_of(self, y: unsafe *Type) -> IterYield {
        if self.pointee(y) == &null {
            return IterYield::Value
        }

        return if (self.is_unsafe_ptr(y)) => (IterYield::UnsafePointer) else => IterYield::Pointer
    }

    /// `n` is a loop over a generator value (a call of a `-> yield *T`
    /// function, a `Yield<*T>`) whose one binder is a safe pointer binder
    /// (`*x`, `const *x`, no ascription): the binder is the pointer the
    /// generator yielded, as `for *x` over an `op in -> yield *T` is, not
    /// the address of the generator's own slot. `elem` is the loop's
    /// element, the yielded pointer type. A plain `x` there is the pointer
    /// value itself.
    fn for_binds_yielded_pointer(self,
                                 n:    unsafe *Statements::RangedForStmt,
                                 elem: unsafe *Type) -> bool {
        if n == &null
            || n->iter_kind != Statements::IterKind::User
            || n->iter_op != &null
            || n->bindings.size() != 1
            || elem == &null {
            return false
        }

        var unsafe *b = n->bindings.get(0)
        if b == &null
            || b->is_discard
            || b->type_ != &null
            || !b->shorthand.has(Statements::BindingShorthand::Pointer)
            || b->shorthand.has(Statements::BindingShorthand::Unsafe)
            || b->shorthand.has(Statements::BindingShorthand::Nullable) {
            return false
        }

        return self.iter_yield_of(elem) == IterYield::Pointer
    }

    /// The binder rule `f` declares: iter_yield_of its written `Yield<T>`'s
    /// `T`, read off the declaration, never an instance's substitution (a
    /// `-> yield T` over `T = *P` yields values), or Free when `f` does
    /// not return a `Yield<T>`. A tuple with a pointer element is Tuple
    /// (fn_iter_yield_elems has each element's rule); a tuple of values
    /// is Value.
    fn fn_iter_yield(self, f: unsafe *Declarations::FunctionDecl) -> IterYield {
        var unsafe *y = self._fn_yielded(f)
        if y == &null {
            return IterYield::Free
        }

        if self.is_tuple(y) {
            var elems = self.tuple_elems(y)
            for var i: usize = 0; i < elems.size(); ++i {
                if self.iter_yield_of(elems[i]) != IterYield::Value {
                    return IterYield::Tuple
                }
            }

            return IterYield::Value
        }

        return self.iter_yield_of(y)
    }

    /// The rule of each element of the tuple `f` declares it yields, in
    /// element order, read off the declaration as fn_iter_yield; empty
    /// when `f` does not yield a tuple.
    fn fn_iter_yield_elems(self,
                           f: unsafe *Declarations::FunctionDecl) -> cxx::std::vector<IterYield> {
        var        out = cxx::std::vector<IterYield>()
        var unsafe *y  = self._fn_yielded(f)
        if y == &null || !self.is_tuple(y) {
            return out
        }

        var elems = self.tuple_elems(y)
        for var i: usize = 0; i < elems.size(); ++i {
            out.push_back(self.iter_yield_of(elems[i]))
        }

        return out
    }

    /// The iteration form (`op in (self)` with `want_const` false,
    /// `op in (const self)` with it true) the record `t` declares, read
    /// off its pattern; null when it declares none.
    fn iteration_form(self,
                      t:          unsafe *Type,
                      want_const: bool) -> unsafe *Declarations::FunctionDecl {
        var unsafe *rd = self.record_decl(self.strip_nullable(self.as_value(t)))
        if rd == &null {
            return &null
        }

        var unsafe *dc = NameLookup::context_of(
            self.pattern_of(NameLookup::representative(rd)),
        )

        if dc == &null {
            return &null
        }

        var unsafe *cell = dc->lookup_symbol(
            DeclName::op_name(TokenKind::KwIn, TokenKind::TkUnknown),
        )

        if cell == &null {
            return &null
        }

        for var i: usize = 0; i < cell->size(); ++i {
            var unsafe *f = dyn_cast<Declarations::FunctionDecl>(cell->get(i))
            if f != &null && f->is_const() == want_const && OperatorFacts::is_iteration(f) {
                return f
            }
        }

        return &null
    }

    /// The `T` of the `Yield<T>` `f` is written to return, or null.
    fn fn_yielded(self, f: unsafe *Declarations::FunctionDecl) -> unsafe *Type {
        return self._fn_yielded(f)
    }

    /// The `T` of the `Yield<T>` `f` is written to return, or null.
    priv fn _fn_yielded(self, f: unsafe *Declarations::FunctionDecl) -> unsafe *Type {
        if f == &null || f->return_type == &null || f->return_type->canonical == &null {
            return &null
        }

        var unsafe *rt = f->return_type->canonical
        if !self.is_lang(rt, WellKnownType::Yield) {
            return &null
        }

        var args = self.record_args(rt)
        if args.size() == 0 {
            return &null
        }

        return args[0]
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

    /// `t`'s pointer levels, each pointee read canonical and unqualified:
    /// `unsafe **i32` is {2, true, i32}, a non-pointer {0, false, `t}`. What
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
        return canon_unqual(peel_ref(t))
    }

    fn record_decl(self, t: unsafe *Type) -> unsafe *Decl {
        var unsafe *u = canon_unqual(t)
        if u == &null || !isa<RecordType>(u) {
            return &null
        }

        return cast<RecordType>(u)->decl
    }

    /// The interfaces a bounded generic parameter `t` promises, as their
    /// canonical instances (`T impl Same`, `T impl Container<U>`), or none
    /// when `t` is not a bare parameter or has no interface bound. The
    /// parameter half of Substitution::bound_ifaces, which every reader
    /// goes through: an associated type's bounds need its base substituted
    /// in, which this layer cannot do.
    fn bound_ifaces(self, t: unsafe *Type) -> cxx::std::vector<unsafe *Type> {
        var        out = cxx::std::vector<unsafe *Type>()
        var unsafe *c  = canon_unqual(t)
        if c == &null || !isa<Types::GenericParamType>(c) {
            return out
        }

        self._declared_ifaces(cast<Types::GenericParamType>(c), &out)
        self.append_clause_ifaces(c, &out)
        return out
    }

    /// bound_ifaces' half from the bound table: what `g`'s own
    /// declaration promised.
    priv fn _declared_ifaces(self,
                             g:          unsafe *Types::GenericParamType,
                             @inout out: cxx::std::vector<unsafe *Type>) {
        var it = self.sc->bounds.find(g->owner as usize as u64)
        if it == self.sc->bounds.end() {
            return
        }

        var *_set = &it->second
        for var i: usize = 0; i < _set->impl_constraints.size(); ++i {
            var unsafe *k  = _set->impl_constraints[i]
            var unsafe *id = dyn_cast<NamedIdentExpr>(k->lhs)
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

            if k->rhs == &null || k->rhs->canonical == &null {
                continue
            }

            out.push_back(canon_unqual(k->rhs->canonical))
        }
    }

    /// The bases a generic parameter `t`'s `derives` bounds promise
    /// (`X derives Mixin<X>`), as canonicals, in clause order; none when
    /// `t` is not a bare parameter. bound_ifaces' twin over the other half
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

            if k->rhs == &null || k->rhs->canonical == &null {
                continue
            }

            out.push_back(canon_unqual(k->rhs->canonical))
        }

        return out
    }

    /// # bounds a body's clauses add

    /// The `impl` conjuncts `f`'s body may rely on that the bound table
    /// does not file under the owner of what they constrain: those of `f`'s
    /// `requires`, of the functions it is nested in, and of the extension
    /// or record it is written in, except a conjunct on a parameter of the
    /// clause's own declaration (the table has that one under it). So a
    /// member's `requires T impl I` on its record's T, and any conjunct on
    /// an associated type (`J::Item impl Eq`), give I's members in the
    /// body, as `<T impl I>` does; C++ drops the member from an instance
    /// that does not meet its clause (Speller::member_requires), so the
    /// body is never instantiated where they do not hold.
    fn body_clauses(self,
                    f: unsafe *Declarations::FunctionDecl) -> cxx::std::vector<unsafe *ConstraintExpr> {
        var        out     = cxx::std::vector<unsafe *ConstraintExpr>()
        var unsafe *d      = unsafe (f as unsafe *Decl)
        var        n:  u32 = 0
        while d != &null && n < 64 {
            n += 1
            self._clause_extras(d, &out)
            if d->lexical_dc == &null {
                break
            }

            d = d->lexical_dc->owner_decl()
        }

        return out
    }

    /// Make `f`'s body_clauses the ones in force (SemaContext::clause_bounds)
    /// and return those they replace, for leave_body. A body typed on demand
    /// in the middle of another one sees its own clauses only.
    fn enter_body(self,
                  f: unsafe *Declarations::FunctionDecl) -> cxx::std::vector<unsafe *ConstraintExpr> {
        var saved = self.sc->clause_bounds
        self.sc->clause_bounds = self.body_clauses(f)
        return saved
    }

    fn leave_body(self, const saved: cxx::std::vector<unsafe *ConstraintExpr>) {
        self.sc->clause_bounds = saved
    }

    /// Append to `out` the interfaces the clauses in force grant the
    /// dependent type `t` (a bare parameter or an associated type), as
    /// canonical instances (`From<U>` keeps its arguments).
    fn append_clause_ifaces(self, t: unsafe *Type, @inout out: cxx::std::vector<unsafe *Type>) {
        var unsafe *c = canon_unqual(t)
        if c == &null || self.sc->clause_bounds.size() == 0 {
            return
        }

        for var i: usize = 0; i < self.sc->clause_bounds.size(); ++i {
            var unsafe *k = self.sc->clause_bounds[i]
            if k->rhs == &null || k->rhs->canonical == &null || !self._clause_names(k, c) {
                continue
            }

            var unsafe *rc = canon_unqual(k->rhs->canonical)
            var        dup = false
            for var j: usize = 0; j < out.size(); ++j {
                if out[j] == rc {
                    dup = true
                    break
                }
            }

            if !dup {
                out.push_back(rc)
            }
        }
    }

    /// Whether conjunct `k` constrains canonical `c`: the same parameter
    /// (index and declaring owner), or the same associated type.
    fn clause_names(self, k: unsafe *ConstraintExpr, c: unsafe *Type) -> bool {
        return self._clause_names(k, canon_unqual(c))
    }

    priv fn _clause_names(self, k: unsafe *ConstraintExpr, c: unsafe *Type) -> bool {
        var unsafe *e  = self.strip_parens(k->lhs)
        var unsafe *id = dyn_cast<NamedIdentExpr>(e)
        if id != &null {
            var unsafe *gp = dyn_cast<Declarations::GenericParamDecl>(
                id->resolved_decl,
            )

            if gp == &null || gp->owner == &null || !isa<Types::GenericParamType>(c) {
                return false
            }

            var unsafe *g = cast<Types::GenericParamType>(c)
            return gp->index == g->param_index
                && NameLookup::representative(gp->owner) == NameLookup::representative(
                    g->owner,
                )
        }

        if !isa<AssocType>(c) {
            return false
        }

        var unsafe *ch = dyn_cast<ChainExpr>(e)
        if ch == &null || ch->steps.size() == 0 {
            return false
        }

        var unsafe *st = ch->steps.get(ch->steps.size() - 1)
        return st->resolved_type != &null && canon_unqual(st->resolved_type) == c
    }

    /// The `impl` conjuncts of declaration `d`'s clause that body_clauses
    /// keeps (see there).
    priv fn _clause_extras(self,
                           d:          unsafe *Decl,
                           @inout out: cxx::std::vector<unsafe *ConstraintExpr>) {
        var cs = cxx::std::vector<unsafe *ConstraintExpr>()
        self.impl_conjuncts(decl_requires_clause(d), &cs)
        for var i: usize = 0; i < cs.size(); ++i {
            var unsafe *id = dyn_cast<NamedIdentExpr>(
                self.strip_parens(cs[i]->lhs),
            )

            if id != &null {
                var unsafe *gp = dyn_cast<Declarations::GenericParamDecl>(
                    id->resolved_decl,
                )

                if gp == &null {
                    continue
                }

                if NameLookup::representative(gp->owner) == NameLookup::representative(
                    d,
                ) {
                    continue
                }
            }

            out.push_back(cs[i])
        }
    }

    /// # a base that is a type parameter
    ///
    /// `class <A derives Base> Hooked derives A`: the edge's canonical is the
    /// parameter, and stays it (Speller writes `: public A`, and each
    /// instance's base is its own argument). What the edge names for a
    /// question is read off the record that asks:
    ///
    ///   - `Hooked<Concrete>`: `Concrete`, the instance's argument;
    ///   - `Hooked<A>`, the class's own body, and `Hooked<U>` in another
    ///     generic: the classes the parameter's `derives` bounds name,
    ///     which is all a body checked once may assume of its base.

    /// The parameter base edge `e` names, or null when `e` names a record
    /// (or nothing). A pack and a value parameter are no base.
    fn param_edge(self, e: unsafe *Declarations::InheritEdge) -> unsafe *Types::GenericParamType {
        if e == &null || e->base == &null || e->base->canonical == &null {
            return &null
        }

        var unsafe *c = canon_unqual(e->base->canonical)
        if c == &null || !isa<Types::GenericParamType>(c) {
            return &null
        }

        return cast<Types::GenericParamType>(c)
    }

    /// The classes parameter `t`'s `derives` bounds name, as canonicals, in
    /// clause order; everything that is no class (an interface, an
    /// unresolved bound) is left out. Read off the owner's requires clause,
    /// where RequiresDesugar keeps every bound, and not off the bound table
    /// bound_bases reads: that one holds the declarations of the file being
    /// checked, and a class deriving its parameter is asked about from every
    /// file that uses it.
    fn bound_classes(self, t: unsafe *Type) -> cxx::std::vector<unsafe *Type> {
        var        out = cxx::std::vector<unsafe *Type>()
        var unsafe *c  = canon_unqual(t)
        if c == &null || !isa<Types::GenericParamType>(c) {
            return out
        }

        var unsafe *g = cast<Types::GenericParamType>(c)
        if g->owner == &null {
            return out
        }

        var unsafe *req = decl_requires_clause(g->owner)
        if req == &null {
            req = decl_requires_clause(NameLookup::representative(g->owner))
        }

        var cs = cxx::std::vector<unsafe *ConstraintExpr>()
        constraint_conjuncts(req, unsafe &cs)
        for var i: usize = 0; i < cs.size(); ++i {
            var unsafe *k = cs[i]
            if !k->is_derives() || k->rhs == &null || k->rhs->canonical == &null {
                continue
            }

            var unsafe *id = dyn_cast<NamedIdentExpr>(k->lhs)
            if id == &null {
                continue
            }

            var unsafe *gp = dyn_cast<Declarations::GenericParamDecl>(
                id->resolved_decl,
            )

            if gp == &null || gp->index != g->param_index || gp->owner == &null {
                continue
            }

            if NameLookup::representative(gp->owner) != NameLookup::representative(
                g->owner,
            ) {
                continue
            }

            var unsafe *b = canon_unqual(k->rhs->canonical)
            var unsafe *d = self.record_decl(b)
            if d != &null
                && isa<Declarations::ClassDecl>(
                    NameLookup::representative(self.pattern_of(d)),
                ) {
                out.push_back(b)
            }
        }

        return out
    }

    /// The records the parameter edge `e` of record type `of` stands for
    /// (see above), as canonicals; none when `e` is no parameter edge. `of`
    /// may be null: the class's own view. `argument_only`: the argument
    /// or nothing, for a question the bound cannot answer for an instance
    /// (what stays pure virtual).
    fn param_edge_bases(self,
                        of:            unsafe *Type,
                        e:             unsafe *Declarations::InheritEdge,
                        argument_only: bool = false) -> cxx::std::vector<unsafe *Type> {
        var        out = cxx::std::vector<unsafe *Type>()
        var unsafe *g  = self.param_edge(e)
        if g == &null {
            return out
        }

        var        args = self.record_args(of)
        var unsafe *od  = self.record_decl(of)
        // A partial's parameters are not the primary's: its edge reads the
        // bound, never an argument by position.
        var own = od != &null
            && NameLookup::representative(self.pattern_of(od)) == NameLookup::representative(
                g->owner,
            )

        if own && (g->param_index as usize) < args.size() && !g->is_pack {
            var unsafe *a = canon_unqual(args[g->param_index as usize])
            if a != &null && isa<RecordType>(a) {
                out.push_back(a)
                return out
            }

            if a != &null && isa<Types::GenericParamType>(a) && !argument_only {
                return self.bound_classes(a)
            }

            return out
        }

        if argument_only {
            return out
        }

        return self.bound_classes(unsafe (g as unsafe *Type))
    }

    /// param_edge_bases for a walk that holds declarations: `holder` is
    /// the class whose edge `e` is, an instance of it, or null.
    fn param_edge_decls(self,
                        holder: unsafe *Decl,
                        e:      unsafe *Declarations::InheritEdge) -> cxx::std::vector<unsafe *Decl> {
        var        out = cxx::std::vector<unsafe *Decl>()
        var unsafe *g  = self.param_edge(e)
        if g == &null {
            return out
        }

        // An implicit instance's arguments are its registry entry's (its
        // own `spec_args` are the written list of an explicit one).
        var bases              = cxx::std::vector<unsafe *Type>()
        var a:    unsafe *Type = &null
        var idx                = g->param_index as usize
        var inst = holder != &null
            && decl_is_instance(holder)
            && !g->is_pack
            && NameLookup::representative(self.pattern_of(holder)) == NameLookup::representative(
                g->owner,
            )

        if inst && self.sc->instances != &null {
            var unsafe *ie = self.sc->instances->entry_of(holder)
            if ie != &null && idx < ie->args.size() {
                a = canon_unqual(ie->args[idx])
            }
        }

        if a != &null && isa<RecordType>(a) {
            bases.push_back(a)
        } else if a != &null && isa<Types::GenericParamType>(a) {
            bases = self.bound_classes(a)
        } else if a == &null {
            bases = self.bound_classes(unsafe (g as unsafe *Type))
        }

        for var i: usize = 0; i < bases.size(); ++i {
            var unsafe *d = self.record_decl(bases[i])
            if d != &null {
                out.push_back(d)
            }
        }

        return out
    }

    /// The declaration of `t` when it is a generic parameter whose body is
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

    /// How a diagnostic names checked head `t`: `T`, or `T::Item`.
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

    /// The interface instance an AssocType for requirement `td` carries
    /// when it is named through `through` (a bound, or the Self of the
    /// interface it is named in): its DECLARING interface, so one entity has
    /// one canonical however it was reached -- `G::Node` through `G impl
    /// Big`, `Big derives Graph`, and Graph's `first() -> Self::Node`
    /// through the same G are the same type. `through` itself when it is
    /// the declaring interface (its arguments are then exact); the plain
    /// record of a non-generic declaring interface; null for one inherited
    /// from a GENERIC interface, whose arguments as seen from `through`
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

    /// The `impl` conjuncts of clause `e`, in clause order.
    fn impl_conjuncts(self, e: unsafe *Expr, @inout out: cxx::std::vector<unsafe *ConstraintExpr>) {
        var cs = cxx::std::vector<unsafe *ConstraintExpr>()
        constraint_conjuncts(e, unsafe &cs)
        for var i: usize = 0; i < cs.size(); ++i {
            if !cs[i]->is_derives() {
                out.push_back(cs[i])
            }
        }
    }

    /// Associated type `ta`'s OWN `impl` bounds (`type Item impl Display`),
    /// in clause order. A generic one's clause also holds its parameters'
    /// (`type <K impl Hash> Map`, hoisted as `K impl Hash`), which
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

    /// The `impl` bounds of generic associated type `ta`'s parameter `k`.
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

    /// Which of `ta`'s own generic parameters conjunct `c` constrains, or
    /// usize(-1) for one about `ta` itself.
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

    /// `d` is declared in the TU being checked.
    fn in_this_tu(self, d: unsafe *Decl) -> bool {
        return NameLookup::ctx_of(d) == self.sc->ctx
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
            return "op " + OperatorFacts::symbol(
                cast<Declarations::FunctionDecl>(d),
            )
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
            return ctx->get_spelling(
                cast<Declarations::EnumVariantDecl>(d)->name,
            )
        }

        if isa<Declarations::GenericParamDecl>(d) {
            return ctx->get_spelling(
                cast<Declarations::GenericParamDecl>(d)->name,
            )
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
    fn first_pure_left(self,
                       d:  unsafe *Decl,
                       of: unsafe *Type = &null) -> unsafe *Declarations::FunctionDecl {
        if d == &null {
            return &null
        }

        var chain  = cxx::std::vector<unsafe *Decl>()
        var depths = cxx::std::vector<u32>()
        self._chain_walk(
            NameLookup::representative(d),
            unsafe &chain,
            unsafe &depths,
            0,
            of,
        )

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
                        depth:  u32,
                        of:     unsafe *Type = &null) {
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
                self._chain_walk(
                    NameLookup::representative(bd),
                    out,
                    depths,
                    depth + 1,
                    canon_unqual(e->base->canonical),
                )
            }

            // A base that is a type parameter: `of`'s argument, when it is
            // a class. While the argument is unknown (the class's own body,
            // an instance over another parameter) so is what it leaves
            // pure, and the walk reports nothing through the edge: an
            // abstract bound does not make every instance abstract.
            var pbs = self.param_edge_bases(of, e, true)
            for var k: usize = 0; k < pbs.size(); ++k {
                var unsafe *pd = self.record_decl(pbs[k])
                if pd != &null {
                    self._chain_walk(
                        NameLookup::representative(pd),
                        out,
                        depths,
                        depth + 1,
                        pbs[k],
                    )
                }
            }
        }

        // an instance's methods and bases are its pattern's.
        var unsafe *pat = self.pattern_of(d)
        if pat != d {
            self._chain_walk(pat, out, depths, depth, of)
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
                       depth: u32,
                       inst:  unsafe *Decl = &null) -> bool {
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

            // A parameter base: `inst`'s argument, else the bound's classes.
            var pds = self.param_edge_decls(inst, e)
            for var k: usize = 0; k < pds.size(); ++k {
                if self._poly_walk(
                    NameLookup::representative(pds[k]),
                    seen,
                    depth + 1,
                ) {
                    return true
                }
            }
        }

        var unsafe *pat = self.pattern_of(d)
        if pat != d {
            return self._poly_walk(pat, seen, depth + 1, d)
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

    /// Is `t` the vector/set/map/string lang record, or its structural form.
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

    /// `t` is a C string parameter a literal's static bytes may stand for:
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

    /// `e` as written is a plain string literal (not an f-string, which
    /// is built at run time, and not a byte string, which is a slice and
    /// converts to no pointer): what a C string parameter of an imported
    /// function takes without a `string` being made. The bare
    /// literal only; a parenthesized one stays a `string`.
    fn c_string_literal(self, e: unsafe *Expr) -> unsafe *StringLiteralExpr {
        if e == &null || e->is_poisoned() || !isa<StringLiteralExpr>(e) {
            return &null
        }

        var unsafe *s = cast<StringLiteralExpr>(e)
        if s->is_format() || s->is_bytes() {
            return &null
        }

        return s
    }

    /// `unsafe *const c_char`: what a string literal's bytes are at the C++
    /// boundary (`const char[N]`, decayed).
    pub fn c_string_ptr_type(self) -> unsafe *Type {
        var unsafe *cc = self.sc->types->qualified(
            self.builtin(BuiltinKind::CChar),
            QUAL_CONST,
        )

        return self.sc->types->pointer(cc, true)
    }

    /// `lit` (c_string_literal said yes) goes out as its bytes, typed
    /// c_string_ptr_type, and no `string` is built from it.
    pub fn mark_c_string(self, lit: unsafe *StringLiteralExpr) {
        lit->c_string = self.c_string_ptr_type()
    }

    /// # tuples
    ///
    /// `(A, B, ..)` is the record `TupleN<A, B, ..>` (TupleRecords): no
    /// canonical is a TupleType after T. Tuple-ness is the pattern's
    /// `tuple_arity`, by identity -- a user's own `Tuple2` is not one.

    /// The tuple record decl `d` is (its pattern has an arity), else false.
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

    /// Field `i` of a tuple canonical, read off the PATTERN (an instance
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

    /// The parameter at `i` across `f`'s WHOLE redeclaration chain that
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

    /// The type a USE of `p` has inside its function. A pack `...xs: T` is
    /// `[T;]` (Slice<T>, by value), a dependent `Slice<T>` when T is a
    /// generic parameter of the function; every other parameter is its
    /// declared canonical. Null for a TYPE pack (`fn <...T> f(...xs: T)`:
    /// one value per element, never a slice) or a type that never resolved.
    /// The declared `type_` stays the element: overload resolution ranks
    /// each pack argument against it, and CallLowering builds the slice from
    /// it.
    fn param_value_type(self, p: unsafe *Declarations::ParamDecl) -> unsafe *Type {
        if p == &null || p->type_ == &null || p->type_->canonical == &null {
            return &null
        }

        var unsafe *c = p->type_->canonical
        if !p->is_pack {
            return c
        }

        var unsafe *elem = canon_unqual(c)
        if elem == &null || param_is_type_pack(p) {
            return &null
        }

        return self.slice_of(elem)
    }

    /// `p`'s index in `f->params`, `self` included; usize(-1) if absent.
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

    /// A lang record's constructor BY SHAPE: `nparams` non-self parameters,
    /// and for `from_slice` the single one is a Slice. Found through the lang
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
            var unsafe *f = dyn_cast<Declarations::FunctionDecl>(
                cell.cell->get(i),
            )

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

    /// How a literal of lang record `k` (Vector, HashSet, HashMap) is built
    /// from elements that cannot be copied. The one place that names the
    /// members: MoveCheck asks whether the build exists, ListLiteralLowering
    /// mints the calls.
    fn literal_build(self, k: WellKnownType) -> LiteralBuild {
        var        out = LiteralBuild{}
        var unsafe *d  = self.sc->well_known->get(k)
        if d == &null {
            return out
        }

        var        map   = k == WellKnownType::HashMap
        var unsafe *body = self.pattern_of(NameLookup::representative(d))
        out.ctor = self.lang_ctor(k, 0, false)
        if out.ctor == &null {
            return out
        }

        out.reserve = self._by_value_method(body, "reserve", 1)
        out.add = self._by_value_method(
            body,
            if (k == WellKnownType::Vector) => ("push") else => "insert",
            if (map) => (2 as usize) else => 1 as usize,
        )

        return out
    }

    /// The public method `name` of record `rd` with `nparams` parameters
    /// after `self`, each taken by value: not `const`, which borrows the
    /// argument and leaves the callee to copy it, and not `@inout`.
    priv fn _by_value_method(self,
                             rd:         unsafe *Decl,
                             const name: string,
                             nparams:    usize) -> unsafe *Decl {
        var ms = decl_methods(rd)
        for var i: usize = 0; i < ms.size(); ++i {
            var unsafe *m = ms[i]
            if m == &null || m->is_operator || !m->is_method() || m->is_const() {
                continue
            }

            if m->visibility == VisibilityKind::Private
                || m->visibility == VisibilityKind::Protected
                || m->generic_params.size() != 0
                || self.decl_name(unsafe (m as unsafe *Decl)) != name {
                continue
            }

            var n: usize = 0
            var ok       = true
            for var p: usize = 0; p < m->params.size(); ++p {
                var unsafe *pd = m->params[p]
                if pd == &null || pd->is_self {
                    continue
                }

                n += 1
                if pd->is_const || pd->is_pack || pd->mode == ParamMode::Inout {
                    ok = false
                }
            }

            if ok && n == nparams {
                return unsafe (m as unsafe *Decl)
            }
        }

        return &null
    }

    /// The literal `lit` is the whole initializer of the local `vd`, of
    /// `vd`'s own type, and `vd` can be written after its declaration: a
    /// literal built by LiteralBuild then fills `vd` itself, and no
    /// container is transferred out of the literal. A `const` local cannot be
    /// written, a `static` one is initialized once, and a namespace-scope
    /// variable has no statement to fill it in.
    fn literal_fills(self, vd: unsafe *Declarations::VariableDecl, lit: unsafe *Expr) -> bool {
        if vd == &null
            || lit == &null
            || vd->init == &null
            || vd->type_ == &null
            || lit->type_ == &null {
            return false
        }

        if vd->is_const()
            || vd->is_static()
            || vd->is_thread
            || self.strip_parens(vd->init) != lit {
            return false
        }

        var unsafe *dc = vd->semantic_dc
        if dc != &null
            && (dc->dc_kind == DeclContextKind::TranslationUnit
                || dc->dc_kind == DeclContextKind::Module) {
            return false
        }

        var unsafe *vt = if (vd->type_->canonical != &null) => (vd->type_->canonical)
                         else => vd->type_
        return canon_has_const(vt) == false && canon_unqual(vt) == canon_unqual(lit->type_)
    }

    /// A member of lang record `k` by name: the record's own, else one an
    /// `extend` block of the record's file declares (the two-word library
    /// declares most of a record's API that way). The first method of that
    /// name when `method`, else the first declaration. Null when neither
    /// scope has it: the caller owns the diagnostic.
    fn lang_member(self,
                   k:          WellKnownType,
                   const name: string,
                   method:     bool = false) -> unsafe *Decl {
        var unsafe *d = self.sc->well_known->get(k)
        if d == &null {
            return &null
        }

        var unsafe *body = self.pattern_of(NameLookup::representative(d))
        var unsafe *own = self._member_in(
            NameLookup::context_of(body),
            name,
            method,
        )

        if own != &null {
            return own
        }

        var unsafe *home = body->semantic_dc
        if home == &null {
            return &null
        }

        self._ext_hit = &null
        for var i: usize = 0; i < home->dc_decls.size() && self._ext_hit == &null; ++i {
            var unsafe *top = *home->dc_decls.get(i)
            if top == &null {
                continue
            }

            for_each_unwrapped_decl(
                top,
                fn (x: unsafe *Decl) { self._ext_probe(x, body, name, method) },
            )
        }

        return self._ext_hit
    }

    /// The member `name` the record type `t` itself declares, in the
    /// pattern its members come from: the partial specialization `t`'s
    /// arguments select (SemaContext::record_partial), where lang_member
    /// answers with the primary's, else the pattern `t` is an instance
    /// of. `[const X;]` is the `Slice<const T>` specialization, and C++
    /// resolves a member of it there. Null when `t` is no record or
    /// declares none.
    fn own_member(self, t: unsafe *Type, const name: string) -> unsafe *Decl {
        var unsafe *rt = dyn_cast<RecordType>(canon_unqual(t))
        if rt == &null || rt->decl == &null {
            return &null
        }

        var        binds = cxx::std::vector<unsafe *Type>()
        var unsafe *body = self.sc->record_partial(t, unsafe &binds)
        if body == &null {
            body = self.pattern_of(NameLookup::representative(rt->decl))
        }

        return self._member_in(
            NameLookup::context_of(NameLookup::representative(body)),
            name,
            false,
        )
    }

    /// lang_member's answer from an `extend` block, written by _ext_probe.
    priv var _ext_hit: unsafe *Decl = &null

    /// `x` is an `extend` block of record pattern `body` that declares
    /// `name`: record the member, unless an earlier block already has.
    priv fn _ext_probe(self,
                       x:          unsafe *Decl,
                       body:       unsafe *Decl,
                       const name: string,
                       method:     bool) {
        if self._ext_hit != &null || !isa<Declarations::ExtensionDecl>(x) {
            return
        }

        var unsafe *e = cast<Declarations::ExtensionDecl>(x)
        if e->target == &null || e->target->canonical == &null {
            return
        }

        var unsafe *rt = dyn_cast<RecordType>(
            canon_unqual(e->target->canonical),
        )

        if rt == &null || rt->decl == &null {
            return
        }

        if self.pattern_of(NameLookup::representative(rt->decl)) != body {
            return
        }

        self._ext_hit = self._member_in(NameLookup::context_of(x), name, method)
    }

    priv fn _member_in(self,
                       dc:         unsafe *DeclContext,
                       const name: string,
                       method:     bool) -> unsafe *Decl {
        if dc == &null {
            return &null
        }

        var imm  = self.sc->imm_table()->intern_ident_copy(name)
        var cell = self.sc->lookup.in_context(dc, DeclName::ident(imm), name)
        if !cell.found() {
            return &null
        }

        if !method {
            return cell.first()
        }

        for var i: usize = 0; i < cell.cell->size(); ++i {
            var unsafe *f = dyn_cast<Declarations::FunctionDecl>(
                cell.cell->get(i),
            )

            if f != &null && f->is_method() {
                return cell.cell->get(i)
            }
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

    /// Empty when a value of `t` can be built from nothing; otherwise why
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

    /// True when whether `t` has a default is the instance's to answer:
    /// a generic parameter or an associated type, or a record with no
    /// declared constructor (a tuple) whose generic arguments include one,
    /// since its implicit default rests on its fields. why_no_default
    /// answers empty for every such type; an array, a pointer and `T?`
    /// answer the same at every instance and are not included.
    fn default_is_dependent(self, t: unsafe *Type) -> bool {
        return self._default_is_dependent(t, 0)
    }

    priv fn _default_is_dependent(self, t: unsafe *Type, depth: u32) -> bool {
        var unsafe *u = canon_unqual(t)
        if u == &null || depth > 16 || !u->is_dependent() {
            return false
        }

        match u->kind {
            case TypeKind::GenericParamType {
                return !cast<Types::GenericParamType>(u)->is_pack
            } case TypeKind::AssocType {
                return true
            } case TypeKind::RecordType {
                0
            } default {
                return false
            }
        }

        var unsafe *rd = self.default_record(u)
        if rd == &null || self.declares_ctor(rd) {
            return false
        }

        var unsafe *r = cast<RecordType>(u)
        for var i: usize = 0; i < r->args.size(); ++i {
            if self._default_is_dependent(r->args[i], depth + 1) {
                return true
            }
        }

        return false
    }

    /// `depth` bounds the walk into fields: a by-value cycle is
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

                var bw = self._why_no_default(
                    canon_unqual(e->base->canonical),
                    depth + 1,
                )

                if !bw.is_empty() {
                    return f"'{nm}' has no default constructor: the implicit one cannot build its base ({bw})"
                }
            }
        }

        var fs = decl_fields(rd)
        for var i: usize = 0; i < fs.size(); ++i {
            var unsafe *f = fs[i]
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

            var fw = self._why_no_default(
                canon_unqual(f->type_->canonical),
                depth + 1,
            )

            if !fw.is_empty() {
                return f"'{nm}' has no default constructor: the implicit one cannot build field '{fnm}', which has no initializer ({fw})"
            }
        }

        return ""
    }

    /// `d` (class or struct) declares a constructor of any kind: one named
    /// after it, a transfer (`@copy` / `@move`) included, deleted included.
    /// Any of them suppresses the implicit default constructor, as a
    /// user-declared constructor of any kind does in C++ -- which is what
    /// the emitted class has to agree with.
    fn declares_ctor(self, d: unsafe *Decl) -> bool {
        var nm = self.decl_name(d)
        var ms = decl_methods(d)
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

    /// The Kairo enum with payloads `t` names (its pattern), else null.
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

    /// The constructor of class or struct `d` callable with no arguments:
    /// not an operator, not a transfer (`@copy`/`@move` build from another
    /// value, not from none), every parameter but `self` defaulted.
    fn default_ctor_of(self, d: unsafe *Decl) -> unsafe *Declarations::FunctionDecl {
        var nm = self.decl_name(d)
        var ms = decl_methods(d)
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

    /// Every element of `lit` whose type `at` says is an array is a
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
    /// said yes), in row-major order, appended to `out`; the innermost
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

    /// Some list literal in `e`, an array initializer, or one nested in
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
        return ExprFacts::strip_parens(e)
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

    /// `t` as a Kairo RETURN type: a C++ reference is spelled the way a
    /// Kairo definition writes it (`T&` is `ffi::ref<T>`, `const T&` is
    /// `ffi::ref<const T>`, `T&&` is `ffi::mref<T>`); anything else as
    /// str() spells it. The fix-its and the hover's `->` read it, so the
    /// spelling they offer is the one the parser takes back.
    pub fn return_str(self, t: unsafe *Type) -> string {
        if t != &null && isa<Types::CXXLValueRefType>(t) {
            return "ffi::ref<" + self.str(
                cast<Types::CXXLValueRefType>(t)->referee,
            ) + ">"
        }

        if t != &null && isa<Types::CXXRValueRefType>(t) {
            return "ffi::mref<" + self.str(
                cast<Types::CXXRValueRefType>(t)->referee,
            ) + ">"
        }

        return self.str(t)
    }

    /// The fix-it text that makes the written return type `written` return
    /// `want` (a canonical), as return_str spells it, but keeping the
    /// user's own spelling of the referenced type when it is the same type
    /// (`cxx::std::string` stays that; str() would print the instance as
    /// `basic_string<c_char, ...>`, which does not parse back). Only the
    /// reference kind and the `const` change then.
    pub fn return_fix(self, written: unsafe *Type, want: unsafe *Type) -> string {
        var unsafe *core = written
        if written != &null && isa<Types::CXXLValueRefType>(written) {
            core = cast<Types::CXXLValueRefType>(written)->referee
        } else if written != &null && isa<Types::CXXRValueRefType>(written) {
            core = cast<Types::CXXRValueRefType>(written)->referee
        }

        var unsafe *wc    = canon_unqual(want)
        var unsafe *wr    = wc
        var        wconst = false
        if wc != &null && isa<Types::CXXLValueRefType>(wc) {
            wr     = cast<Types::CXXLValueRefType>(wc)->referee
            wconst = canon_has_const(wr)
        } else if wc != &null && isa<Types::CXXRValueRefType>(wc) {
            wr     = cast<Types::CXXRValueRefType>(wc)->referee
            wconst = canon_has_const(wr)
        }

        if core == &null
            || core->canonical == &null
            || (!core->range.is_valid())
            || canon_unqual(core->canonical) != canon_unqual(wr) {
            return self.return_str(want)
        }

        var text = self.sc->ctx->get_spelling(core->range)
        if text.starts_with("const ") {
            text = text.subslice(6, text.size() - 6)
        }

        var cv = if (wconst) => ("const ") else => ""
        if wc != &null && isa<Types::CXXLValueRefType>(wc) {
            return "ffi::ref<" + cv + text + ">"
        }

        if wc != &null && isa<Types::CXXRValueRefType>(wc) {
            return "ffi::mref<" + cv + text + ">"
        }

        return text
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
                    return "[" + self.str(a->element) + "; " + self.str(
                        a->extent_param,
                    ) + "]"
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
                        return "(" + self.str(v->vops[0]) + " as " + self.str(
                            v->vty,
                        ) + ")"
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
                                s.push(b)
                                continue
                            }

                            s += "\\x"
                            s.push(digits.data()[(b >> (4 as u8)) as usize])
                            s.push(digits.data()[(b & (15 as u8)) as usize])
                        }

                        s += "\""
                        return s
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

            // The C++ spelling clang gave it (`std::FILE`, `__m128i`). A constant
            // name would tie in EffectPropagation's order and fall back to
            // addresses.
            case TypeKind::OpaqueFFIType {
                var sp = cast<Types::OpaqueFFIType>(t)->text()
                if sp.size() == 0 {
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
