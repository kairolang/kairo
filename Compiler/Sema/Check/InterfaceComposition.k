/// --- The Kairo Project ------------ Sema/Check/InterfaceComposition.k --- ///
///
///   \brief Normalize an algebraic interface into a regular one: a plain
///          requirement list, before binding and conformance see it.
///
///   \detail
///     `interface Foo derives X + (Y - Z) & W` composes requirement sets:
///     `+` union, `-` difference, `&` intersection (Compiler/Spec/Interfaces.md#interface-algebra). The parser keeps the clause as the expression it
///     read (InterfaceDecl::derives_expr), each leaf resolved as a type in
///     derives_list. This pass evaluates it, unions in the interface's own
///     members, and writes InterfaceDecl::requirements: every requirement,
///     deduplicated, as if written out by hand. Every interface gets one, a
///     plain union and one with no `derives` included (D4: one model).
///
///   \par Identity (D3)
///     A method requirement is its name, receiver (none / `self` / `const
///     self`), its own generic parameters with their bounds, and its
///     parameter modes and types, each source interface's `Self` normalized
///     to the composed interface's and its parameters bound by the leaf's
///     arguments. Not its return type: `+` of two identical requirements
///     that return different types is a conflict, and `-` / `&` match on
///     identity alone. Generic bounds are compared as the set of `impl` /
///     `derives` conjuncts on each own parameter; a requirement carrying a
///     value predicate is identical only to itself. An associated type is
///     its name: `+` merges two (bounds of both, one default or a
///     conflict), `-` removes it, `&` keeps it with the bounds both state.
///
///   \par Errors
///     A `+` conflict, a leaf that is not an interface, a cycle, a kept
///     method naming an associated type the result removed (`Self::N`), and
///     an interface with no requirements at all (D8).
///
///   \par The LSP hook (D10)
///     derived_text(I) is the derived part of I's body as Kairo source, the
///     text an inlay hint shows after the derives clause; `--print-sema`
///     prints it, so tests pin what an LSP will show.
///
///   Phase: TYPES, after TypeResolution and RedeclMerge (leaves resolved),
///   before ConstraintExtraction and ChainBinding (a bound `T impl Foo`
///   gets its members at binding).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::DeclContext
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    FunctionDecl,
    InterfaceDecl,
    ModuleDecl,
    Requirement,
    TypeAliasDecl,
}
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    ConstraintExpr,
}
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Types::ChainType
import AST::OperatorFacts::OperatorFacts
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::SemaContext
import Sema::Type::ArgumentDeduction::Deduction
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

/// Every `Self::N` a declaration's written types name: N's spelling and
/// where it was written.
pub class _SelfAssocUses derives RecursiveASTVisitor<_SelfAssocUses> {
    pub var ctx:    unsafe *ASTContext            = &null
    pub var names:  cxx::std::vector<string>
    pub var ranges: cxx::std::vector<SourceRange>
    fn _SelfAssocUses(self) { }

    fn visit_type(self, t: *Type) -> bool {
        var *ct? = dyn_cast<ChainType>(t)
        if ct == &null || ct->segments.size() < 2 || self.ctx == &null {
            return true
        }

        var unsafe *s0 = ct->segments.get(0)
        if s0->name == &null || self.ctx->get_spelling(s0->name->name) != "Self" {
            return true
        }

        var unsafe *s1 = ct->segments.get(1)
        if s1->name == &null {
            return true
        }

        self.names.push_back(self.ctx->get_spelling(s1->name->name))
        self.ranges.push_back(s1->range)
        return true
    }
}

pub class InterfaceComposition {
    pub var  sc: unsafe *SemaContext
    priv var tu: TypeUtil

    fn InterfaceComposition(self, sc: unsafe *SemaContext) {
        self.sc = sc
        self.tu = TypeUtil(sc)
    }

    fn run(self) {
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
            return
        }

        self._walk(tu)
    }

    priv fn _walk(self, dc: unsafe *DeclContext) {
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *d = *dc->dc_decls.get(i)
            if d == &null || d->is_poisoned() {
                continue
            }

            if isa<InterfaceDecl>(d) {
                self.compose(cast<InterfaceDecl>(d))
                continue
            }

            if isa<ModuleDecl>(d) {
                self._walk((cast<ModuleDecl>(d)))
            }
        }
    }

    /// # one interface

    /// Compose \p id once: its derives expression, then its own members.
    /// False when it is poisoned (reported here or by an operand).
    fn compose(self, id: unsafe *InterfaceDecl) -> bool {
        if id->compose_state == 2 {
            return !id->is_poisoned()
        }

        if id->compose_state == 1 {
            var b = self.sc->diag->report(
                DiagID::SC164E,
                id->range.start,
                f"interface '{self.tu.decl_name((unsafe (id as unsafe *Decl)))}' derives from itself",
            )

            b.first(self._name_range(id))
            b.emit()
            id->poison()
            return false
        }

        id->compose_state = 1
        var out = cxx::std::vector<Requirement>()
        var ok  = true
        if id->derives_expr != &null {
            var leaf: usize = 0
            ok = self._eval(id, id->derives_expr, unsafe &leaf, &out)
        }

        if ok {
            var own = cxx::std::vector<Requirement>()
            self._own(id, unsafe &own)
            ok = self._union(id, unsafe &out, &own, id->derives_end)
        }

        if ok && out.size() == 0 {
            var b = self.sc->diag->report(
                DiagID::SC165E,
                id->range.start,
                f"interface '{self.tu.decl_name((unsafe (id as unsafe *Decl)))}' has no requirements; every type conforms to it, so it constrains nothing. Remove it",
            )

            b.first(self._name_range(id))
            b.emit()
            ok = false
        }

        if ok {
            ok = self._check_dangling(id, out)
        }

        if ok {
            var unsafe *ctx = NameLookup::ctx_of(unsafe (id as unsafe *Decl))
            var unsafe *arr = ctx->alloc_array<Requirement>(out.size())
            for var i: usize = 0; i < out.size(); ++i {
                arr[i] = out[i]
            }

            id->requirements.from_raw(arr, out.size())
        } else {
            id->poison()
        }

        id->compose_state = 2
        return ok
    }

    /// Evaluate derives subexpression \p e. Leaves are consumed in source
    /// order, leaf i being derives_list[i] (the parser's contract).
    priv fn _eval(self,
                  id:         unsafe *InterfaceDecl,
                  e:          unsafe *Expr,
                  leaf:       unsafe *usize,
                  @inout out: cxx::std::vector<Requirement>) -> bool {
        var unsafe *b = dyn_cast<BinaryOperatorExpr>(e)
        if b != &null {
            var l = cxx::std::vector<Requirement>()
            var r = cxx::std::vector<Requirement>()
            if !self._eval(id, b->lhs, leaf, &l) {
                return false
            }

            if !self._eval(id, b->rhs, leaf, &r) {
                return false
            }

            var k = b->op_token.kind
            if k == TokenKind::OpPlus {
                if !self._union(id, unsafe &l, &r, b->op_token.range) {
                    return false
                }

                for var i: usize = 0; i < l.size(); ++i {
                    out.push_back(l[i])
                }

                return true
            }

            if k == TokenKind::OpMinus {
                for var i: usize = 0; i < l.size(); ++i {
                    if self._find(id, unsafe &l[i], &r) == usize::MAX {
                        out.push_back(l[i])
                    }
                }

                return true
            }

            // `&`: what both require; an associated type keeps the bounds both state.
            for var i: usize = 0; i < l.size(); ++i {
                var j = self._find(id, unsafe &l[i], &r)
                if j == usize::MAX {
                    continue
                }

                var keep = l[i]
                if isa<TypeAliasDecl>(keep.decl) {
                    self._intersect_assoc(&keep, &r[j])
                }

                out.push_back(keep)
            }

            return true
        }

        // A leaf.
        var i = *leaf
        *leaf = i + 1
        if i >= id->derives_list.size() {
            kairo::std::ice_fail(
                "InterfaceComposition: more derives leaves than derives_list entries; the parser's contract",
            )
        }

        var unsafe *edge = id->derives_list.get(i)
        var unsafe *t = if (edge->base != &null && edge->base->canonical != &null) => (canon_unqual(
                            edge->base->canonical,
                        ))
                        else => &null
        if t == &null { // TypeResolution reported it.
            return false
        }

        var unsafe *jd = self._iface_of(t)
        if jd == &null {
            var bd = self.sc->diag->report(
                DiagID::SC166E,
                edge->range.start,
                f"'{self.tu.str(t)}' is not an interface; a 'derives' clause composes interfaces",
            )

            bd.first(edge->range)
            bd.emit()
            return false
        }

        if !self.compose(jd) {
            return false
        }

        for var k: usize = 0; k < jd->requirements.size(); ++k {
            var rq = *jd->requirements.get(k)
            rq.source = self._through(rq.source, t)
            rq.leaf   = (i as u32)
            out.push_back(rq)
        }

        return true
    }

    /// `l + r` into \p l: each of \p r's requirements joins unless identical
    /// to one already there; an associated type merges. A `+` conflict is
    /// reported at \p at.
    priv fn _union(self,
                   id:       unsafe *InterfaceDecl,
                   l:        unsafe *cxx::std::vector<Requirement>,
                   @inout r: cxx::std::vector<Requirement>,
                   at:       SourceRange) -> bool {
        var ok = true
        for var i: usize = 0; i < r.size(); ++i {
            var j = self._find(id, unsafe &(r)[i], &*l)
            if j == usize::MAX {
                l->push_back((r)[i])
                continue
            }

            var unsafe *a = unsafe &(*l)[j]
            var unsafe *b = unsafe &(r)[i]
            if a->decl == b->decl { // one decl reached twice (a diamond).
                continue
            }

            if isa<TypeAliasDecl>(a->decl) {
                if !self._merge_assoc(id, a, b, at) {
                    ok = false
                }

                continue
            }

            var unsafe *fa = cast<FunctionDecl>(a->decl)
            var unsafe *fb = cast<FunctionDecl>(b->decl)
            if self._norm(id, a, fa->return_type, &null) != self._norm(
                id,
                b,
                fb->return_type,
                fa,
            ) {
                var nm = self._name(a->decl)
                var d = self.sc->diag->report(
                    DiagID::SC167E,
                    at.start,
                    f"'{nm}' is required twice with the same parameters and different return types; one requirement cannot return both",
                )

                d.first(at)
                d.note(
                    a->decl->range.start,
                    f"'{nm}' returning '{self._type_text(id, a, fa->return_type)}' is declared here",
                )->child_first(a->decl->range)
                d.note(
                    b->decl->range.start,
                    f"'{nm}' returning '{self._type_text(id, b, fb->return_type)}' is declared here",
                )->child_first(b->decl->range)
                d.emit()
                ok = false
            }
        }

        return ok
    }

    /// Two `type N`s under `+`: one, with the bounds of both and at most one
    /// default; two different defaults are a conflict.
    priv fn _merge_assoc(self,
                         id: unsafe *InterfaceDecl,
                         a:  unsafe *Requirement,
                         b:  unsafe *Requirement,
                         at: SourceRange) -> bool {
        var unsafe *da = self._canon(a->default_ty)
        var unsafe *db = self._canon(b->default_ty)
        if da != &null && db != &null && da != db {
            var nm = self._name(a->decl)
            var d = self.sc->diag->report(
                DiagID::SC168E,
                at.start,
                f"associated type '{nm}' is given two different defaults, '{self.tu.str(da)}' and '{self.tu.str(db)}'",
            )

            d.first(at)
            d.note(
                a->decl->range.start,
                f"'{nm} = {self.tu.str(da)}' is declared here",
            )->child_first(a->decl->range)

            d.note(
                b->decl->range.start,
                f"'{nm} = {self.tu.str(db)}' is declared here",
            )->child_first(b->decl->range)

            d.emit()
            return false
        }

        if da == &null && db != &null {
            a->default_ty = b->default_ty
        }

        // The bounds of both, as one requires-style conjunction: no list, no
        // new predicate form (D9). A bound both already state is not repeated.
        var add = cxx::std::vector<unsafe *ConstraintExpr>()
        self._conjuncts(b->bounds, unsafe &add)
        var have = cxx::std::vector<unsafe *ConstraintExpr>()
        self._conjuncts(a->bounds, unsafe &have)
        for var i: usize = 0; i < add.size(); ++i {
            if self._has_bound(have, add[i]) {
                continue
            }

            if a->bounds == &null {
                a->bounds = unsafe (add[i] as unsafe *Expr)
                continue
            }

            var and_tok = self.sc->ctx->make_token(
                at,
                TokenKind::OpAmpAmp,
                "&&",
            )

            a->bounds = unsafe (BinaryOperatorExpr::create(self.sc->ctx, at, a->bounds, unsafe (add[i] as unsafe *Expr), and_tok) as unsafe *Expr)
        }

        return true
    }

    /// `type N` under `&`: only the bounds both state, and a default only if
    /// both give the same one.
    priv fn _intersect_assoc(self, a: *Requirement, b: *Requirement) {
        if self._canon(a->default_ty) != self._canon(b->default_ty) {
            a->default_ty = &null
        }

        var mine = cxx::std::vector<unsafe *ConstraintExpr>()
        self._conjuncts(a->bounds, unsafe &mine)
        var theirs = cxx::std::vector<unsafe *ConstraintExpr>()
        self._conjuncts(b->bounds, unsafe &theirs)
        var kept: unsafe *Expr = &null
        for var i: usize = 0; i < mine.size(); ++i {
            if !self._has_bound(theirs, mine[i]) {
                continue
            }

            if kept == &null {
                kept = unsafe (mine[i] as unsafe *Expr)
                continue
            }

            var and_tok = self.sc->ctx->make_token(
                mine[i]->range,
                TokenKind::OpAmpAmp,
                "&&",
            )

            kept = unsafe (BinaryOperatorExpr::create(self.sc->ctx, mine[i]->range, kept, unsafe (mine[i] as unsafe *Expr), and_tok) as unsafe *Expr)
        }

        a->bounds = kept
    }

    /// \p id's own members, each its own requirement.
    priv fn _own(self, id: unsafe *InterfaceDecl, out: unsafe *cxx::std::vector<Requirement>) {
        var unsafe *me = self._self_instance(id)
        for var i: usize = 0; i < id->methods.size(); ++i {
            var unsafe *m = id->methods[i]
            if m == &null || m->is_poisoned() {
                continue
            }

            out->push_back(
                self._req(unsafe (m as unsafe *Decl), me, &null, &null),
            )
        }

        var unsafe *dc = unsafe (id as unsafe *DeclContext)
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *ta = dyn_cast<TypeAliasDecl>(*dc->dc_decls.get(i))
            if ta == &null || !ta->is_associated || ta->is_poisoned() {
                continue
            }

            out->push_back(self._req(ta, me, ta->requires_clause, ta->aliased))
        }
    }

    priv fn _req(self,
                 d:      unsafe *Decl,
                 source: unsafe *Type,
                 bounds: unsafe *Expr,
                 dflt:   unsafe *Type) -> Requirement {
        var r = Requirement{}
        r.decl       = d
        r.source     = source
        r.leaf       = u32::MAX
        r.bounds     = bounds
        r.default_ty = dflt
        return r
    }

    /// # identity (D3)

    /// The index in \p pool of a requirement identical to \p a, or usize(-1).
    priv fn _find(self,
                  id:          unsafe *InterfaceDecl,
                  a:           unsafe *Requirement,
                  @inout pool: cxx::std::vector<Requirement>) -> usize {
        for var i: usize = 0; i < pool.size(); ++i {
            if self._same(id, a, unsafe &(pool)[i]) {
                return i
            }
        }

        return usize::MAX
    }

    priv fn _same(self,
                  id: unsafe *InterfaceDecl,
                  a:  unsafe *Requirement,
                  b:  unsafe *Requirement) -> bool {
        if a->decl == b->decl {
            return self._through_same(a, b)
        }

        var ta = isa<TypeAliasDecl>(a->decl)
        if ta != isa<TypeAliasDecl>(b->decl) {
            return false
        }

        if self._name(a->decl) != self._name(b->decl) {
            return false
        }

        if ta { // an associated type is its name.
            return true
        }

        var unsafe *fa = cast<FunctionDecl>(a->decl)
        var unsafe *fb = cast<FunctionDecl>(b->decl)
        if fa->is_method() != fb->is_method() {
            return false
        }

        if fa->is_method() && fa->is_const() != fb->is_const() {
            return false
        }

        if fa->is_operator != fb->is_operator || fa->params.size() != fb->params.size() {
            return false
        }

        if fa->generic_params.size() != fb->generic_params.size() {
            return false
        }

        for var i: usize = 0; i < fa->params.size(); ++i {
            var unsafe *pa = fa->params[i]
            var unsafe *pb = fb->params[i]
            if pa == &null || pb == &null {
                return false
            }

            if pa->is_self != pb->is_self {
                return false
            }

            if pa->is_self {
                continue
            }

            if pa->mode != pb->mode || pa->is_pack != pb->is_pack {
                return false
            }

            if self._norm(id, a, pa->type_, &null) != self._norm(
                id,
                b,
                pb->type_,
                fa,
            ) {
                return false
            }
        }

        // `op as` is overloaded on its target (RedeclMerge::_same_signature),
        // so two of them with different results are two requirements -- the
        // witness names carry the target (LowerTargets::witness_conversion).
        if fa->is_operator
            && OperatorFacts::op_kind(fa) == TokenKind::KwAs
            && self._norm(id, a, fa->return_type, &null) != self._norm(
                id,
                b,
                fb->return_type,
                fa,
            ) {
            return false
        }

        return self._same_bounds(id, a, b)
    }

    /// The same decl through two leaves is one requirement only through the
    /// same instance: `Container<i32> + Container<string>` keeps both `get`s.
    priv fn _through_same(self, a: unsafe *Requirement, b: unsafe *Requirement) -> bool {
        return self._canon(a->source) == self._canon(b->source)
    }

    /// Trap A: the own generic parameters' bounds, as sets per parameter.
    priv fn _same_bounds(self,
                         id: unsafe *InterfaceDecl,
                         a:  unsafe *Requirement,
                         b:  unsafe *Requirement) -> bool {
        var unsafe *fa = cast<FunctionDecl>(a->decl)
        var unsafe *fb = cast<FunctionDecl>(b->decl)
        if fa->requires_clause == &null && fb->requires_clause == &null {
            return true
        }

        var ca = cxx::std::vector<unsafe *ConstraintExpr>()
        var cb = cxx::std::vector<unsafe *ConstraintExpr>()
        if !self._conjuncts(fa->requires_clause, unsafe &ca) { // a value predicate: identical only to itself.
            return false
        }

        if !self._conjuncts(fb->requires_clause, unsafe &cb) {
            return false
        }

        if ca.size() != cb.size() {
            return false
        }

        for var i: usize = 0; i < ca.size(); ++i {
            var found = false
            for var j: usize = 0; j < cb.size(); ++j {
                if self._same_conjunct(id, a, ca[i], b, cb[j], fa) {
                    found = true
                    break
                }
            }

            if !found {
                return false
            }
        }

        return true
    }

    priv fn _same_conjunct(self,
                           id: unsafe *InterfaceDecl,
                           a:  unsafe *Requirement,
                           x:  unsafe *ConstraintExpr,
                           b:  unsafe *Requirement,
                           y:  unsafe *ConstraintExpr,
                           fa: unsafe *FunctionDecl) -> bool {
        if x->is_derives() != y->is_derives() {
            return false
        }

        if self._param_index(x, cast<FunctionDecl>(a->decl)) != self._param_index(
            y,
            cast<FunctionDecl>(b->decl),
        ) {
            return false
        }

        return self._norm(id, a, x->rhs, &null) == self._norm(id, b, y->rhs, fa)
    }

    priv fn _param_index(self, c: unsafe *ConstraintExpr, f: unsafe *FunctionDecl) -> i64 {
        var unsafe *n = dyn_cast<NamedIdentExpr>(c->lhs)
        if n == &null {
            return -1
        }

        for var i: usize = 0; i < f->generic_params.size(); ++i {
            if (f->generic_params[i]) == n->resolved_decl {
                return i as i64
            }
        }

        return -1
    }

    /// The `impl` / `derives` conjuncts of requires clause \p e. False when it
    /// also has a value predicate.
    priv fn _conjuncts(self,
                       e:   unsafe *Expr,
                       out: unsafe *cxx::std::vector<unsafe *ConstraintExpr>) -> bool {
        if e == &null {
            return true
        }

        var unsafe *b = dyn_cast<BinaryOperatorExpr>(e)
        if b != &null
            && (b->op_token.kind == TokenKind::OpAmpAmp || b->op_token.kind == TokenKind::KwAnd) {
            var l = self._conjuncts(b->lhs, out)
            var r = self._conjuncts(b->rhs, out)
            return l && r
        }

        var unsafe *c = dyn_cast<ConstraintExpr>(e)
        if c == &null {
            return false
        }

        out->push_back(c)
        return true
    }

    priv fn _has_bound(self,
                       const set: cxx::std::vector<unsafe *ConstraintExpr>,
                       c:         unsafe *ConstraintExpr) -> bool {
        for var i: usize = 0; i < set.size(); ++i {
            var unsafe *x = (set)[i]
            if x->is_derives() == c->is_derives() && self._canon(x->rhs) == self._canon(c->rhs) {
                return true
            }
        }

        return false
    }

    /// Requirement \p r's type \p t as the composed interface \p id sees it:
    /// the source interface's parameters bound by r's instance, its `Self`
    /// replaced by \p id's, and -- when comparing against \p other -- r's own
    /// generic parameters bound to other's by position. Canonical, cv dropped.
    priv fn _norm(self,
                  id:    unsafe *InterfaceDecl,
                  r:     unsafe *Requirement,
                  t:     unsafe *Type,
                  other: unsafe *FunctionDecl) -> unsafe *Type {
        var unsafe *c = self._canon(t)
        if c == &null {
            return &null
        }

        var d = Deduction(self.sc, &null)
        if c->is_dependent() {
            d.bind_from_record(r->source)
            var unsafe *f = dyn_cast<FunctionDecl>(r->decl)
            if f != &null && other != &null {
                var unsafe *fr = NameLookup::representative(r->decl)
                var unsafe *orep = NameLookup::representative(
                    unsafe (other as unsafe *Decl),
                )

                for var i: usize = 0; i < f->generic_params.size() && i < other->generic_params.size(); ++i {
                    d.bind(
                        fr,
                        f->generic_params[i]->index,
                        self.sc->types->generic_param(
                            orep,
                            other->generic_params[i]->index,
                            other->generic_params[i]->is_pack,
                        ),
                    )
                }
            }

            var unsafe *s = d.substitute(c)
            if s != &null {
                c = s
            }
        }

        var unsafe *k = self._iface_of(r->source)
        if k == &null {
            return canon_unqual(c)
        }

        var empty = cxx::std::vector<unsafe *Type>()
        return canon_unqual(
            d.replace_self(
                c,
                unsafe (k as unsafe *Decl),
                self.sc->types->record(
                    NameLookup::representative(unsafe (id as unsafe *Decl)),
                    unsafe &empty,
                ),
            ),
        )
    }

    /// # Trap B

    /// A kept method that names `Self::N` where the result has no associated
    /// type N: nothing would supply it.
    priv fn _check_dangling(self,
                            id:         unsafe *InterfaceDecl,
                            const reqs: cxx::std::vector<Requirement>) -> bool {
        var have = cxx::std::vector<string>()
        for var i: usize = 0; i < reqs.size(); ++i {
            if isa<TypeAliasDecl>((reqs)[i].decl) {
                have.push_back(self._name((reqs)[i].decl))
            }
        }

        var ok = true
        for var i: usize = 0; i < reqs.size(); ++i {
            var unsafe *m = dyn_cast<FunctionDecl>((reqs)[i].decl)
            if m == &null {
                continue
            }

            var uses = _SelfAssocUses()
            uses.ctx = NameLookup::ctx_of(unsafe (m as unsafe *Decl))
            uses.dispatch_decl(unsafe (m as unsafe *Decl))
            for var k: usize = 0; k < uses.names.size(); ++k {
                var present = false
                for var j: usize = 0; j < have.size(); ++j {
                    if have[j] == uses.names[k] {
                        present = true
                        break
                    }
                }

                if present {
                    continue
                }

                var nm = self._name(m)
                var at = if (id->derives_expr != &null) => (id->derives_expr->range)
                         else => self._name_range(id)
                var d = self.sc->diag->report(
                    DiagID::SC169E,
                    at.start,
                    f"this composition removes associated type '{uses.names[k]}' but keeps '{nm}', which names 'Self::{uses.names[k]}'; nothing would supply the type",
                )

                d.first(at)
                d.note(uses.ranges[k].start, f"'{nm}' names it here")->child_first(
                    uses.ranges[k],
                )

                d.emit()
                ok = false
            }
        }

        return ok
    }

    /// # the LSP hook (D10)

    /// The derived part of \p id's body as Kairo source -- what an inlay
    /// hint shows after its derives clause -- or "" when nothing is derived.
    fn derived_text(self, id: unsafe *InterfaceDecl) -> string {
        var body = ""
        for var i: usize = 0; i < id->requirements.size(); ++i {
            var unsafe *r = id->requirements.get(i)
            if r->leaf == u32::MAX {
                continue
            }

            body += "    " + self._spell(id, r) + "\n"
        }

        if body.size() == 0 {
            return ""
        }

        return "{\n" + body + "}"
    }

    priv fn _spell(self, id: unsafe *InterfaceDecl, r: unsafe *Requirement) -> string {
        if isa<TypeAliasDecl>(r->decl) {
            var s  = "type " + self._name(r->decl)
            var cs = cxx::std::vector<unsafe *ConstraintExpr>()
            self._conjuncts(r->bounds, unsafe &cs)
            for var i: usize = 0; i < cs.size(); ++i {
                s += if (i == 0) => (" impl ") else => ", "
                s += self._type_text(id, r, cs[i]->rhs)
            }

            if r->default_ty != &null {
                s += " = " + self._type_text(id, r, r->default_ty)
            }

            return s
        }

        var unsafe *f = cast<FunctionDecl>(r->decl)
        var        s  = ""
        if !f->is_method() {
            s += "static "
        }

        s += "fn "
        if f->generic_params.size() > 0 {
            s += "<"
            for var i: usize = 0; i < f->generic_params.size(); ++i {
                if i > 0 {
                    s += ", "
                }

                s += self.tu.decl_name(
                    unsafe (f->generic_params[i] as unsafe *Decl),
                )
            }

            s += "> "
        }

        s += self._name(r->decl) + "("
        var first = true
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null {
                continue
            }

            if !first {
                s += ", "
            }

            first = false
            if p->is_self {
                s += if (f->is_const()) => ("const self") else => "self"
                continue
            }

            s += self.tu.param_name(p) + ": " + self._type_text(id, r, p->type_)
        }

        s += ")"
        if f->return_type != &null {
            s += " -> " + self._type_text(id, r, f->return_type)
        }

        return s
    }

    /// \p t as the source interface's arguments make it, its bare `Self`
    /// spelled `Self`.
    priv fn _type_text(self,
                       id: unsafe *InterfaceDecl,
                       r:  unsafe *Requirement,
                       t:  unsafe *Type) -> string {
        if t == &null {
            return "void"
        }

        // Unresolved (`Self::Item` before associated types resolve): as written.
        if t->canonical == &null {
            return self._written(r, t)
        }

        var unsafe *c = self._canon(t)
        if c->is_dependent() {
            var d = Deduction(self.sc, &null)
            d.bind_from_record(r->source)
            var unsafe *s = d.substitute(c)
            if s != &null {
                c = canon_unqual(s)
            }
        }

        var unsafe *k = self._iface_of(r->source)
        if k != &null
            && isa<RecordType>(c)
            && cast<RecordType>(c)->args.size() == 0
            && NameLookup::representative(
                self.tu.pattern_of(cast<RecordType>(c)->decl),
            ) == k {
            return "Self"
        }

        return self.tu.str(c)
    }

    /// A written type with no canonical, spelled from its path segments.
    priv fn _written(self, r: unsafe *Requirement, t: unsafe *Type) -> string {
        var unsafe *ct = dyn_cast<ChainType>(t)
        if ct == &null {
            return "<type>"
        }

        var unsafe *ctx = NameLookup::ctx_of(r->decl)
        var        s    = ""
        for var i: usize = 0; i < ct->segments.size(); ++i {
            var unsafe *seg = ct->segments.get(i)
            if i > 0 {
                s += "::"
            }

            if seg->name != &null {
                s += ctx->get_spelling(seg->name->name)
            }
        }

        return s
    }

    /// # small helpers

    /// `name`, or `op +=` for an operator, spelled in the decl's own context.
    priv fn _name(self, d: unsafe *Decl) -> string {
        var unsafe *f = dyn_cast<FunctionDecl>(d)
        if f == &null || !f->is_operator {
            return self.tu.decl_name(d)
        }

        var unsafe *ctx = NameLookup::ctx_of(d)
        var        s    = "op "
        for var i: usize = 0; i < f->op_token.size(); ++i {
            s += ctx->get_spelling(f->op_token[i])
        }

        return s
    }

    /// Requirement source \p src (canonical in its interface's parameters)
    /// as reached through leaf type \p leaf: those parameters bound by the leaf's arguments.
    priv fn _through(self, src: unsafe *Type, leaf: unsafe *Type) -> unsafe *Type {
        var unsafe *c = self._canon(src)
        if c == &null || !c->is_dependent() {
            return c
        }

        var d = Deduction(self.sc, &null)
        d.bind_from_record(leaf)
        var unsafe *s = d.substitute(c)
        return if (s != &null) => (canon_unqual(s)) else => c
    }

    /// \p id's own instance: record(id) at its own parameters.
    priv fn _self_instance(self, id: unsafe *InterfaceDecl) -> unsafe *Type {
        var unsafe *rep = NameLookup::representative(
            unsafe (id as unsafe *Decl),
        )

        var args = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < id->generic_params.size(); ++i {
            var unsafe *gp = id->generic_params[i]
            if gp == &null {
                continue
            }

            args.push_back(
                self.sc->types->generic_param(rep, gp->index, gp->is_pack),
            )
        }

        return self.sc->types->record(rep, unsafe &args)
    }

    priv fn _iface_of(self, t: unsafe *Type) -> unsafe *InterfaceDecl {
        var unsafe *c = self._canon(t)
        if c == &null || !isa<RecordType>(c) {
            return &null
        }

        var unsafe *d = NameLookup::representative(
            self.tu.pattern_of(cast<RecordType>(c)->decl),
        )

        return dyn_cast<InterfaceDecl>(d)
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

    priv fn _name_range(self, id: unsafe *InterfaceDecl) -> SourceRange {
        return id->name.range
    }
}
