/// --- The Kairo Project ---------------- Sema/InterfaceComposition.k --- ///
///
///   \brief Normalize an algebraic interface into a regular one: a plain
///          requirement list, before binding and conformance see it.
///
///   \detail
///     `interface Foo derives X + (Y - Z) & W` composes requirement sets:
///     `+` union, `-` difference, `&` intersection (private/PLAN-interface-
///     algebra.md, D2-D4). The parser keeps the clause as the expression it
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import Sema::SemaContext::*;
import Sema::Resolve::NameLookup::*;
import Sema::Type::TypeUtil::*;
import Sema::Type::ArgumentDeduction::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::OperatorFacts::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Kind::ExprKind::*;
import AST::Kind::TypeKind::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::TokenKind::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;

/// Every `Self::N` a declaration's written types name: N's spelling and
/// where it was written.
class _SelfAssocUses derives RecursiveASTVisitor::<_SelfAssocUses> {
    pub var ctx:    *ASTContext = &null;
    pub var names:  vec::<string>;
    pub var ranges: vec::<SourceRange>;
    fn _SelfAssocUses(self) { }

    fn visit_type(self, t: *Type) -> bool {
        var ct = dyn_cast::<ChainType>(t);
        if (ct == &null) || (ct->segments.size() < 2) || (self.ctx == &null) { return true; }
        var s0 = ct->segments.get(0);
        if (s0->name == &null) || (self.ctx->get_spelling(s0->name->name) != "Self") { return true; }
        var s1 = ct->segments.get(1);
        if s1->name == &null { return true; }
        self.names.push_back(self.ctx->get_spelling(s1->name->name));
        self.ranges.push_back(s1->range);
        return true;
    }
}

class InterfaceComposition {
    pub var sc: *SemaContext;
    priv var tu: TypeUtil;

    fn InterfaceComposition(self, sc: *SemaContext) {
        self.sc = sc;
        self.tu = TypeUtil(sc);
    }

    fn run(self) {
        var tu = self.sc->tu;
        if (tu == &null) || (tu->program == &null) { return; }
        self._walk(static_cast::<*DeclContext>(tu));
    }

    priv fn _walk(self, dc: *DeclContext) {
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var d = *(dc->dc_decls.get(i));
            if (d == &null) || d->is_poisoned() { continue; }
            if isa::<InterfaceDecl>(d) { self.compose(cast::<InterfaceDecl>(d)); continue; }
            if isa::<ModuleDecl>(d) { self._walk(static_cast::<*DeclContext>(cast::<ModuleDecl>(d))); }
        }
    }

    // --- one interface -------------------------------------------------------------

    /// Compose \p id once: its derives expression, then its own members.
    /// False when it is poisoned (reported here or by an operand).
    fn compose(self, id: *InterfaceDecl) -> bool {
        if id->compose_state == 2 { return !id->is_poisoned(); }
        if id->compose_state == 1 {
            var b = self.sc->diag->report(DiagID::SC001E, id->range.start,
                f"interface '{self.tu.decl_name(static_cast::<*Decl>(id))}' derives from itself");
            b.first(self._name_range(id));
            b.emit();
            id->poison();
            return false;
        }
        id->compose_state = 1;
        var out = vec::<Requirement>();
        var ok = true;
        if id->derives_expr != &null {
            var leaf: usize = 0;
            ok = self._eval(id, id->derives_expr, &leaf, &out);
        }
        if ok {
            var own = vec::<Requirement>();
            self._own(id, &own);
            ok = self._union(id, &out, &own, id->derives_end);
        }
        if ok && (out.size() == 0) {
            var b = self.sc->diag->report(DiagID::SC001E, id->range.start,
                f"interface '{self.tu.decl_name(static_cast::<*Decl>(id))}' has no requirements; every type conforms to it, so it constrains nothing. Remove it");
            b.first(self._name_range(id));
            b.emit();
            ok = false;
        }
        if ok { ok = self._check_dangling(id, &out); }
        if ok {
            var ctx = NameLookup::ctx_of(static_cast::<*Decl>(id));
            var arr = ctx->alloc_array::<Requirement>(out.size());
            for var i: usize = 0; i < out.size(); ++i { arr[i] = out[i]; }
            id->requirements.from_raw(arr, out.size());
        } else {
            id->poison();
        }
        id->compose_state = 2;
        return ok;
    }

    /// Evaluate derives subexpression \p e. Leaves are consumed in source
    /// order, leaf i being derives_list[i] (the parser's contract).
    priv fn _eval(self, id: *InterfaceDecl, e: *Expr, leaf: *usize, out: *vec::<Requirement>) -> bool {
        var b = dyn_cast::<BinaryOperatorExpr>(e);
        if b != &null {
            var l = vec::<Requirement>();
            var r = vec::<Requirement>();
            if !self._eval(id, b->lhs, leaf, &l) { return false; }
            if !self._eval(id, b->rhs, leaf, &r) { return false; }
            var k = b->op_token.kind;
            if k == TokenKind::OpPlus {
                if !self._union(id, &l, &r, b->op_token.range) { return false; }
                for var i: usize = 0; i < l.size(); ++i { out->push_back(l[i]); }
                return true;
            }
            if k == TokenKind::OpMinus {
                for var i: usize = 0; i < l.size(); ++i {
                    if self._find(id, &(l[i]), &r) == usize(-1) { out->push_back(l[i]); }
                }
                return true;
            }
            // `&`: what both require; an associated type keeps the bounds both state.
            for var i: usize = 0; i < l.size(); ++i {
                var j = self._find(id, &(l[i]), &r);
                if j == usize(-1) { continue; }
                var keep = l[i];
                if isa::<TypeAliasDecl>(keep.decl) { self._intersect_assoc(&keep, &(r[j])); }
                out->push_back(keep);
            }
            return true;
        }
        // A leaf.
        var i = *leaf;
        (*leaf) = i + 1;
        if i >= id->derives_list.size() { ICE_FAIL("InterfaceComposition: more derives leaves than derives_list entries; the parser's contract"); }
        var edge = id->derives_list.get(i);
        var t = (canon_unqual(edge->base->canonical)) if ((edge->base != &null) && (edge->base->canonical != &null)) else (&null);
        if t == &null { return false; }   // TypeResolution reported it.
        var jd = self._iface_of(t);
        if jd == &null {
            var bd = self.sc->diag->report(DiagID::SC001E, edge->range.start,
                f"'{self.tu.str(t)}' is not an interface; a 'derives' clause composes interfaces");
            bd.first(edge->range);
            bd.emit();
            return false;
        }
        if !self.compose(jd) { return false; }
        for var k: usize = 0; k < jd->requirements.size(); ++k {
            var rq = *(jd->requirements.get(k));
            rq.source = self._through(rq.source, t);
            rq.leaf   = static_cast::<u32>(i);
            out->push_back(rq);
        }
        return true;
    }

    /// `l + r` into \p l: each of \p r's requirements joins unless identical
    /// to one already there; an associated type merges. A `+` conflict is
    /// reported at \p at.
    priv fn _union(self, id: *InterfaceDecl, l: *vec::<Requirement>, r: *vec::<Requirement>, at: SourceRange) -> bool {
        var ok = true;
        for var i: usize = 0; i < r->size(); ++i {
            var j = self._find(id, &((*r)[i]), l);
            if j == usize(-1) { l->push_back((*r)[i]); continue; }
            var a = &((*l)[j]);
            var b = &((*r)[i]);
            if a->decl == b->decl { continue; }   // one decl reached twice (a diamond).
            if isa::<TypeAliasDecl>(a->decl) {
                if !self._merge_assoc(id, a, b, at) { ok = false; }
                continue;
            }
            var fa = cast::<FunctionDecl>(a->decl);
            var fb = cast::<FunctionDecl>(b->decl);
            if self._norm(id, a, fa->return_type, &null) != self._norm(id, b, fb->return_type, fa) {
                var nm = self._name(a->decl);
                var d = self.sc->diag->report(DiagID::SC001E, at.start,
                    f"'{nm}' is required twice with the same parameters and different return types; one requirement cannot return both");
                d.first(at);
                d.note(a->decl->range.start, f"'{nm}' returning '{self._type_text(id, a, fa->return_type)}' is declared here").first(a->decl->range);
                d.note(b->decl->range.start, f"'{nm}' returning '{self._type_text(id, b, fb->return_type)}' is declared here").first(b->decl->range);
                d.emit();
                ok = false;
            }
        }
        return ok;
    }

    /// Two `type N`s under `+`: one, with the bounds of both and at most one
    /// default; two different defaults are a conflict.
    priv fn _merge_assoc(self, id: *InterfaceDecl, a: *Requirement, b: *Requirement, at: SourceRange) -> bool {
        var da = self._canon(a->default_ty);
        var db = self._canon(b->default_ty);
        if (da != &null) && (db != &null) && (da != db) {
            var nm = self._name(a->decl);
            var d = self.sc->diag->report(DiagID::SC001E, at.start,
                f"associated type '{nm}' is given two different defaults, '{self.tu.str(da)}' and '{self.tu.str(db)}\x27");
            d.first(at);
            d.note(a->decl->range.start, f"'{nm} = {self.tu.str(da)}' is declared here").first(a->decl->range);
            d.note(b->decl->range.start, f"'{nm} = {self.tu.str(db)}' is declared here").first(b->decl->range);
            d.emit();
            return false;
        }
        if (da == &null) && (db != &null) { a->default_ty = b->default_ty; }
        // The bounds of both, as one requires-style conjunction: no list, no
        // new predicate form (D9). A bound both already state is not repeated.
        var add = vec::<*ConstraintExpr>();
        self._conjuncts(b->bounds, &add);
        var have = vec::<*ConstraintExpr>();
        self._conjuncts(a->bounds, &have);
        for var i: usize = 0; i < add.size(); ++i {
            if self._has_bound(&have, add[i]) { continue; }
            if a->bounds == &null { a->bounds = static_cast::<*Expr>(add[i]); continue; }
            var and_tok = self.sc->ctx->make_token(at, TokenKind::OpAmpAmp, "&&");
            a->bounds = static_cast::<*Expr>(BinaryOperatorExpr::create(self.sc->ctx, at, a->bounds, static_cast::<*Expr>(add[i]), and_tok));
        }
        return true;
    }

    /// `type N` under `&`: only the bounds both state, and a default only if
    /// both give the same one.
    priv fn _intersect_assoc(self, a: *Requirement, b: *Requirement) {
        if self._canon(a->default_ty) != self._canon(b->default_ty) { a->default_ty = &null; }
        var mine = vec::<*ConstraintExpr>();
        self._conjuncts(a->bounds, &mine);
        var theirs = vec::<*ConstraintExpr>();
        self._conjuncts(b->bounds, &theirs);
        var kept: *Expr = &null;
        for var i: usize = 0; i < mine.size(); ++i {
            if !self._has_bound(&theirs, mine[i]) { continue; }
            if kept == &null { kept = static_cast::<*Expr>(mine[i]); continue; }
            var and_tok = self.sc->ctx->make_token(mine[i]->range, TokenKind::OpAmpAmp, "&&");
            kept = static_cast::<*Expr>(BinaryOperatorExpr::create(self.sc->ctx, mine[i]->range, kept, static_cast::<*Expr>(mine[i]), and_tok));
        }
        a->bounds = kept;
    }

    /// \p id's own members, each its own requirement.
    priv fn _own(self, id: *InterfaceDecl, out: *vec::<Requirement>) {
        var me = self._self_instance(id);
        for var i: usize = 0; i < id->methods.size(); ++i {
            var m = id->methods[i];
            if (m == &null) || m->is_poisoned() { continue; }
            out->push_back(self._req(static_cast::<*Decl>(m), me, &null, &null));
        }
        var dc = static_cast::<*DeclContext>(id);
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var ta = dyn_cast::<TypeAliasDecl>(*(dc->dc_decls.get(i)));
            if (ta == &null) || (!ta->is_associated) || ta->is_poisoned() { continue; }
            out->push_back(self._req(static_cast::<*Decl>(ta), me, ta->requires_clause, ta->aliased));
        }
    }

    priv fn _req(self, d: *Decl, source: *Type, bounds: *Expr, dflt: *Type) -> Requirement {
        var r = Requirement{};
        r.decl       = d;
        r.source     = source;
        r.leaf       = u32(-1);
        r.bounds     = bounds;
        r.default_ty = dflt;
        return r;
    }

    // --- identity (D3) ---------------------------------------------------------------

    /// The index in \p pool of a requirement identical to \p a, or usize(-1).
    priv fn _find(self, id: *InterfaceDecl, a: *Requirement, pool: *vec::<Requirement>) -> usize {
        for var i: usize = 0; i < pool->size(); ++i {
            if self._same(id, a, &((*pool)[i])) { return i; }
        }
        return usize(-1);
    }

    priv fn _same(self, id: *InterfaceDecl, a: *Requirement, b: *Requirement) -> bool {
        if a->decl == b->decl { return self._through_same(a, b); }
        var ta = isa::<TypeAliasDecl>(a->decl);
        if ta != isa::<TypeAliasDecl>(b->decl) { return false; }
        if self._name(a->decl) != self._name(b->decl) { return false; }
        if ta { return true; }   // an associated type is its name.
        var fa = cast::<FunctionDecl>(a->decl);
        var fb = cast::<FunctionDecl>(b->decl);
        if fa->is_method() != fb->is_method() { return false; }
        if fa->is_method() && (fa->is_const() != fb->is_const()) { return false; }
        if (fa->is_operator != fb->is_operator) || (fa->params.size() != fb->params.size()) { return false; }
        if fa->generic_params.size() != fb->generic_params.size() { return false; }
        for var i: usize = 0; i < fa->params.size(); ++i {
            var pa = fa->params[i];
            var pb = fb->params[i];
            if (pa == &null) || (pb == &null) { return false; }
            if pa->is_self != pb->is_self { return false; }
            if pa->is_self { continue; }
            if (pa->mode != pb->mode) || (pa->is_pack != pb->is_pack) { return false; }
            if self._norm(id, a, pa->type_, &null) != self._norm(id, b, pb->type_, fa) { return false; }
        }
        // `op as` is overloaded on its target (RedeclMerge::_same_signature),
        // so two of them with different results are two requirements -- the
        // witness names carry the target (LowerTargets::witness_conversion).
        if fa->is_operator && (OperatorFacts::op_kind(fa) == TokenKind::KwAs)
        && (self._norm(id, a, fa->return_type, &null) != self._norm(id, b, fb->return_type, fa)) { return false; }
        return self._same_bounds(id, a, b);
    }

    /// The same decl through two leaves is one requirement only through the
    /// same instance: `Container<i32> + Container<string>` keeps both `get`s.
    priv fn _through_same(self, a: *Requirement, b: *Requirement) -> bool {
        return self._canon(a->source) == self._canon(b->source);
    }

    /// Trap A: the own generic parameters' bounds, as sets per parameter.
    priv fn _same_bounds(self, id: *InterfaceDecl, a: *Requirement, b: *Requirement) -> bool {
        var fa = cast::<FunctionDecl>(a->decl);
        var fb = cast::<FunctionDecl>(b->decl);
        if (fa->requires_clause == &null) && (fb->requires_clause == &null) { return true; }
        var ca = vec::<*ConstraintExpr>();
        var cb = vec::<*ConstraintExpr>();
        if !self._conjuncts(fa->requires_clause, &ca) { return false; }   // a value predicate: identical only to itself.
        if !self._conjuncts(fb->requires_clause, &cb) { return false; }
        if ca.size() != cb.size() { return false; }
        for var i: usize = 0; i < ca.size(); ++i {
            var found = false;
            for var j: usize = 0; j < cb.size(); ++j {
                if self._same_conjunct(id, a, ca[i], b, cb[j], fa) { found = true; break; }
            }
            if !found { return false; }
        }
        return true;
    }

    priv fn _same_conjunct(self, id: *InterfaceDecl, a: *Requirement, x: *ConstraintExpr,
                           b: *Requirement, y: *ConstraintExpr, fa: *FunctionDecl) -> bool {
        if x->is_derives() != y->is_derives() { return false; }
        if self._param_index(x, cast::<FunctionDecl>(a->decl)) != self._param_index(y, cast::<FunctionDecl>(b->decl)) { return false; }
        return self._norm(id, a, x->rhs, &null) == self._norm(id, b, y->rhs, fa);
    }

    priv fn _param_index(self, c: *ConstraintExpr, f: *FunctionDecl) -> i64 {
        var n = dyn_cast::<NamedIdentExpr>(c->lhs);
        if n == &null { return -1; }
        for var i: usize = 0; i < f->generic_params.size(); ++i {
            if static_cast::<*Decl>(f->generic_params[i]) == n->resolved_decl { return static_cast::<i64>(i); }
        }
        return -1;
    }

    /// The `impl` / `derives` conjuncts of requires clause \p e. False when it
    /// also has a value predicate.
    priv fn _conjuncts(self, e: *Expr, out: *vec::<*ConstraintExpr>) -> bool {
        if e == &null { return true; }
        var b = dyn_cast::<BinaryOperatorExpr>(e);
        if (b != &null) && ((b->op_token.kind == TokenKind::OpAmpAmp) || (b->op_token.kind == TokenKind::KwAnd)) {
            var l = self._conjuncts(b->lhs, out);
            var r = self._conjuncts(b->rhs, out);
            return l && r;
        }
        var c = dyn_cast::<ConstraintExpr>(e);
        if c == &null { return false; }
        out->push_back(c);
        return true;
    }

    priv fn _has_bound(self, set: *vec::<*ConstraintExpr>, c: *ConstraintExpr) -> bool {
        for var i: usize = 0; i < set->size(); ++i {
            var x = (*set)[i];
            if (x->is_derives() == c->is_derives()) && (self._canon(x->rhs) == self._canon(c->rhs)) { return true; }
        }
        return false;
    }

    /// Requirement \p r's type \p t as the composed interface \p id sees it:
    /// the source interface's parameters bound by r's instance, its `Self`
    /// replaced by \p id's, and -- when comparing against \p other -- r's own
    /// generic parameters bound to other's by position. Canonical, cv dropped.
    priv fn _norm(self, id: *InterfaceDecl, r: *Requirement, t: *Type, other: *FunctionDecl) -> *Type {
        var c = self._canon(t);
        if c == &null { return &null; }
        var d = Deduction(self.sc, &null);
        if c->is_dependent() {
            d.bind_from_record(r->source);
            var f = dyn_cast::<FunctionDecl>(r->decl);
            if (f != &null) && (other != &null) {
                var fr = NameLookup::representative(r->decl);
                var orep = NameLookup::representative(static_cast::<*Decl>(other));
                for var i: usize = 0; (i < f->generic_params.size()) && (i < other->generic_params.size()); ++i {
                    d.bind(fr, f->generic_params[i]->index, self.sc->types->generic_param(orep, other->generic_params[i]->index, other->generic_params[i]->is_pack));
                }
            }
            var s = d.substitute(c);
            if s != &null { c = s; }
        }
        var k = self._iface_of(r->source);
        if k == &null { return canon_unqual(c); }
        var empty = vec::<*Type>();
        return canon_unqual(d.replace_self(c, static_cast::<*Decl>(k), self.sc->types->record(NameLookup::representative(static_cast::<*Decl>(id)), &empty)));
    }

    // --- Trap B ------------------------------------------------------------------------

    /// A kept method that names `Self::N` where the result has no associated
    /// type N: nothing would supply it.
    priv fn _check_dangling(self, id: *InterfaceDecl, reqs: *vec::<Requirement>) -> bool {
        var have = vec::<string>();
        for var i: usize = 0; i < reqs->size(); ++i {
            if isa::<TypeAliasDecl>((*reqs)[i].decl) { have.push_back(self._name((*reqs)[i].decl)); }
        }
        var ok = true;
        for var i: usize = 0; i < reqs->size(); ++i {
            var m = dyn_cast::<FunctionDecl>((*reqs)[i].decl);
            if m == &null { continue; }
            var uses = _SelfAssocUses();
            uses.ctx = NameLookup::ctx_of(static_cast::<*Decl>(m));
            uses.dispatch_decl(static_cast::<*Decl>(m));
            for var k: usize = 0; k < uses.names.size(); ++k {
                var present = false;
                for var j: usize = 0; j < have.size(); ++j { if have[j] == uses.names[k] { present = true; break; } }
                if present { continue; }
                var nm = self._name(static_cast::<*Decl>(m));
                var at = (id->derives_expr->range) if (id->derives_expr != &null) else (self._name_range(id));
                var d = self.sc->diag->report(DiagID::SC001E, at.start,
                    f"this composition removes associated type '{uses.names[k]}' but keeps '{nm}', which names 'Self::{uses.names[k]}'; nothing would supply the type");
                d.first(at);
                d.note(uses.ranges[k].start, f"'{nm}' names it here").first(uses.ranges[k]);
                d.emit();
                ok = false;
            }
        }
        return ok;
    }

    // --- the LSP hook (D10) ----------------------------------------------------------

    /// The derived part of \p id's body as Kairo source -- what an inlay
    /// hint shows after its derives clause -- or "" when nothing is derived.
    fn derived_text(self, id: *InterfaceDecl) -> string {
        var body = "";
        for var i: usize = 0; i < id->requirements.size(); ++i {
            var r = id->requirements.get(i);
            if r->leaf == u32(-1) { continue; }
            body += "    " + self._spell(id, r) + "\n";
        }
        if body.size() == 0 { return ""; }
        return "{\n" + body + "}";
    }

    priv fn _spell(self, id: *InterfaceDecl, r: *Requirement) -> string {
        if isa::<TypeAliasDecl>(r->decl) {
            var s = "type " + self._name(r->decl);
            var cs = vec::<*ConstraintExpr>();
            self._conjuncts(r->bounds, &cs);
            for var i: usize = 0; i < cs.size(); ++i {
                s += (" impl ") if (i == 0) else (", ");
                s += self._type_text(id, r, cs[i]->rhs);
            }
            if r->default_ty != &null { s += " = " + self._type_text(id, r, r->default_ty); }
            return s;
        }
        var f = cast::<FunctionDecl>(r->decl);
        var s = "";
        if !f->is_method() { s += "static "; }
        s += "fn ";
        if f->generic_params.size() > 0 {
            s += "<";
            for var i: usize = 0; i < f->generic_params.size(); ++i {
                if i > 0 { s += ", "; }
                s += self.tu.decl_name(static_cast::<*Decl>(f->generic_params[i]));
            }
            s += "> ";
        }
        s += self._name(r->decl) + "(";
        var first = true;
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if p == &null { continue; }
            if !first { s += ", "; }
            first = false;
            if p->is_self { s += ("const self") if (f->is_const()) else ("self"); continue; }
            s += self.tu.param_name(p) + ": " + self._type_text(id, r, p->type_);
        }
        s += ")";
        if f->return_type != &null { s += " -> " + self._type_text(id, r, f->return_type); }
        return s;
    }

    /// \p t as the source interface's arguments make it, its bare `Self`
    /// spelled `Self`.
    priv fn _type_text(self, id: *InterfaceDecl, r: *Requirement, t: *Type) -> string {
        if t == &null { return "void"; }
        // Unresolved (`Self::Item` before associated types resolve): as written.
        if t->canonical == &null { return self._written(r, t); }
        var c = self._canon(t);
        if c->is_dependent() {
            var d = Deduction(self.sc, &null);
            d.bind_from_record(r->source);
            var s = d.substitute(c);
            if s != &null { c = canon_unqual(s); }
        }
        var k = self._iface_of(r->source);
        if (k != &null) && isa::<RecordType>(c) && (cast::<RecordType>(c)->args.size() == 0)
        && (NameLookup::representative(self.tu.pattern_of(cast::<RecordType>(c)->decl)) == static_cast::<*Decl>(k)) {
            return "Self";
        }
        return self.tu.str(c);
    }

    /// A written type with no canonical, spelled from its path segments.
    priv fn _written(self, r: *Requirement, t: *Type) -> string {
        var ct = dyn_cast::<ChainType>(t);
        if ct == &null { return "<type>"; }
        var ctx = NameLookup::ctx_of(r->decl);
        var s = "";
        for var i: usize = 0; i < ct->segments.size(); ++i {
            var seg = ct->segments.get(i);
            if i > 0 { s += "::"; }
            if seg->name != &null { s += ctx->get_spelling(seg->name->name); }
        }
        return s;
    }

    // --- small helpers ----------------------------------------------------------------

    /// `name`, or `op +=` for an operator, spelled in the decl's own context.
    priv fn _name(self, d: *Decl) -> string {
        var f = dyn_cast::<FunctionDecl>(d);
        if (f == &null) || (!f->is_operator) { return self.tu.decl_name(d); }
        var ctx = NameLookup::ctx_of(d);
        var s = "op ";
        for var i: usize = 0; i < f->op_token.size(); ++i { s += ctx->get_spelling(f->op_token[i]); }
        return s;
    }

    /// Requirement source \p src (canonical in its interface's parameters)
    /// as reached through leaf type \p leaf: those parameters bound by the leaf's arguments.
    priv fn _through(self, src: *Type, leaf: *Type) -> *Type {
        var c = self._canon(src);
        if (c == &null) || (!c->is_dependent()) { return c; }
        var d = Deduction(self.sc, &null);
        d.bind_from_record(leaf);
        var s = d.substitute(c);
        return (canon_unqual(s)) if (s != &null) else (c);
    }

    /// \p id's own instance: record(id) at its own parameters.
    priv fn _self_instance(self, id: *InterfaceDecl) -> *Type {
        var rep = NameLookup::representative(static_cast::<*Decl>(id));
        var args = vec::<*Type>();
        for var i: usize = 0; i < id->generic_params.size(); ++i {
            var gp = id->generic_params[i];
            if gp == &null { continue; }
            args.push_back(self.sc->types->generic_param(rep, gp->index, gp->is_pack));
        }
        return self.sc->types->record(rep, &args);
    }

    priv fn _iface_of(self, t: *Type) -> *InterfaceDecl {
        var c = self._canon(t);
        if (c == &null) || (!isa::<RecordType>(c)) { return &null; }
        var d = NameLookup::representative(self.tu.pattern_of(cast::<RecordType>(c)->decl));
        return dyn_cast::<InterfaceDecl>(d);
    }

    priv fn _canon(self, t: *Type) -> *Type {
        if t == &null { return &null; }
        var c = t->canonical;
        if c == &null { c = t; }
        return canon_unqual(c);
    }

    priv fn _name_range(self, id: *InterfaceDecl) -> SourceRange {
        return id->name.range;
    }
}
