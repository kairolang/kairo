/// --- The Kairo Project --------------------- Sema/Check/WhereGuardCheck.k --- ///
///
///   \brief Judge every `where` dispatch group: what may be guarded, that a
///          group has a fallback, that its members agree, and which guards
///          can never fire or overlap an earlier one (where.mdx).
///
///   \detail
///     A group is the same-signature overloads of one name in one scope,
///     at least one of them guarded. RedeclMerge stamped each member's
///     `where_lead`; a guarded function with no same-signature sibling is a
///     group of one, stamped here. Every group this pass passes goes to
///     SemaContext::where_groups in DISPATCH order -- the guarded members as
///     declared, then the fallback -- for WhereDispatchLowering, which folds
///     it into one function.
///
///   \par Errors
///     - a guard on an interface method (interfaces are zero-cost), on an
///       `unsafe` overload (a separate namespace that never joins a group),
///       or on a declaration with no body;
///     - no fallback: no unguarded member, and the guards were not proven
///       to cover every value (below);
///     - members disagreeing on return type, `const self`, `inline`,
///       `async`, `eval`, `-> !`, or virtual-ness.
///     Two unguarded definitions are R029E, from RedeclMerge.
///
///   \par Panics
///     A member may panic; the dispatcher's set is the union of its
///     members' (where.mdx, PANIC.md §2.8). The group is filed on its lead
///     (FunctionDecl::where_group) for EffectPropagation to take the union.
///
///   \par Not yet supported (SC116E)
///     A guarded `virtual` / `override` method (a dispatcher in a vtable has
///     no rule yet), a generic
///     function (its parameter types are dependent, so RedeclMerge never
///     finds two signatures the same, and a template dispatcher's calls
///     need the per-instance registry entries M2 builds; a METHOD of a
///     generic record is fine, its members are instantiated with the
///     class), an extension member (ExtensionLowering rewrites its
///     receiver; not yet tried with a dispatcher), a default argument
///     (the dispatcher would have to carry the right one), a guarded
///     operator or constructor (neither can be renamed), an out-of-line
///     guarded definition, a forward declaration in a group, a guarded
///     generator, an `async` member (an `eval` one is EvalUsageChecking's
///     error: eval.mdx forbids `where` there), and a variadic one (the
///     dispatcher would forward a pack).
///
///   \par The decision procedure (warnings and coverage)
///     A guard is SIMPLE when it is `true`, `false`, or a conjunction (`&&`)
///     of atoms, each comparing one integer parameter with an integer
///     constant ConstEval folds (`x > 0`, `100 >= x`, `x == 3`; not `!=`),
///     or naming a bool parameter (`ok`, `!ok`). A simple guard is a BOX:
///     one interval per parameter, the type's whole range where it says
///     nothing. Everything else is not simple, and nothing is said about it.
///
///     Values are i64. A 64-bit unsigned parameter's range is cut at
///     i64::MAX: an atom whose constant is above that is not simple, so
///     every value above it satisfies exactly the atoms i64::MAX does, and
///     the cut changes no answer.
///
///     For each simple guard, against the simple guards dispatched before
///     it:
///       - an empty box never holds: warning;
///       - a box inside one earlier box, or inside the union of earlier
///         boxes that constrain only the same one parameter, never fires:
///         warning, with a note at the earlier guard;
///       - a box that meets an earlier one, neither containing the other,
///         overlaps it: warning (where.mdx, "Overlapping Conditions"). An
///         earlier box INSIDE a later one is the documented priority idiom
///         (`x > 100` before `x > 0`) and says nothing.
///     A group with no unguarded member still has a fallback when its
///     guards cover every value: one of them is `true`, or the union of the
///     boxes constraining only one parameter is that parameter's whole
///     range. The last guarded member is then called without being tested.
///
///   Phase: CHECKS, after ExprTyper (guards are typed, so a literal has the
///   type ConstEval folds it in) and before FeatureGateCheck.
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
import Sema::Check::ConstEval::*;
import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Types::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Visitor::RecursiveASTVisitor::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;
import Diagnostic::Registry::*;

class WhereGuardCheck derives RecursiveASTVisitor::<WhereGuardCheck> {
    pub var sc: *SemaContext;
    priv var _tu: TypeUtil;
    priv var _ce: ConstEval;

    /// Every function seen with a guard or a stamp, once each: a method in a
    /// visibility group is reached through the group and the method list.
    priv var _seen: vec::<*FunctionDecl>;

    // The boxes of the group being judged, flat: member m's interval for
    // parameter p is [_lo[m * _np + p], _hi[m * _np + p]].
    priv var _np:     usize = 0;
    priv var _lo:     vec::<i64>;
    priv var _hi:     vec::<i64>;
    priv var _simple: vec::<bool>;
    priv var _empty:  vec::<bool>;
    // Each parameter's whole range, and whether it is one the boxes speak
    // of at all (an integer or a bool).
    priv var _dlo:    vec::<i64>;
    priv var _dhi:    vec::<i64>;
    priv var _dok:    vec::<bool>;

    fn WhereGuardCheck(self, sc: *SemaContext) {
        self.sc  = sc;
        self._tu = TypeUtil(sc);
        self._ce = ConstEval(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved);
        var tu = self.sc->tu;
        if (tu == &null) || (tu->program == &null) { return; }

        var items = &(tu->program->items);
        for var i: usize = 0; i < items->size(); ++i {
            if self.stop { break; }
            var item = *(items->get(i));
            switch item.get_kind() {
                case TopLevelKind::Decl { self.dyn()->dispatch_decl(item.as_decl()); }
                case TopLevelKind::Stmt { self.dyn()->dispatch_stmt(item.as_stmt()); }
                case TopLevelKind::Expr { self.dyn()->dispatch_expr(item.as_expr()); }
            }
        }

        // Groups in the order their first member was met, which is source
        // order within a scope.
        for var i: usize = 0; i < self._seen.size(); ++i {
            var f = self._seen[i];
            var lead = (f->where_lead) if (f->where_lead != &null) else (f);
            if lead != f { continue; }
            self._judge(lead);
        }
    }

    fn traverse_function_decl(self, n: *FunctionDecl) -> *FunctionDecl {
        if n == &null { return n; }
        var out = RecursiveASTVisitor::<WhereGuardCheck>::traverse_function_decl(n);
        if n->is_poisoned() { return out; }
        if (!n->has_where()) && (n->where_lead == &null) { return out; }
        for var i: usize = 0; i < self._seen.size(); ++i {
            if self._seen[i] == n { return out; }
        }
        // A lone guarded function leads its own group of one.
        if n->where_lead == &null { n->where_lead = n; }
        self._seen.push_back(n);
        return out;
    }

    // === one group ============================================================

    priv fn _judge(self, lead: *FunctionDecl) {
        // Members in source order. RedeclMerge picked the lead as the first
        // of them, so the lead is members[0].
        var members = vec::<*FunctionDecl>();
        for var i: usize = 0; i < self._seen.size(); ++i {
            var f = self._seen[i];
            if f->where_lead == lead { members.push_back(f); }
        }
        if members.size() == 0 { return; }
        var name = self._tu.decl_name(static_cast::<*Decl>(lead));

        var ok = true;
        for var i: usize = 0; i < members.size(); ++i {
            if !self._member_ok(members[i], name) { ok = false; }
        }
        if !ok { return; }
        if !self._members_agree(&members, name) { return; }

        // Dispatch order: the guarded members as declared, then the fallback.
        var order = vec::<*FunctionDecl>();
        var fallback: *FunctionDecl = &null;
        for var i: usize = 0; i < members.size(); ++i {
            if members[i]->has_where() { order.push_back(members[i]); }
            else { fallback = members[i]; }
        }

        self._build_boxes(&order);
        self._warn(&order, name);

        if fallback == &null {
            if !self._covers(&order) {
                var g = order[0];
                var b = self.sc->diag->report(DiagID::SC001E, g->range.start,
                    f"no fallback overload for '{name}' when where condition fails");
                b.first(g->where_clause->range);
                b.note(DiagID::SC001N, g->range.start,
                    "add an overload without a 'where' clause to handle all remaining cases");
                b.emit();
                for var i: usize = 0; i < members.size(); ++i { members[i]->poison(); }
                return;
            }
        } else {
            order.push_back(fallback);
        }

        for var i: usize = 0; i < order.size(); ++i { self.sc->where_groups.push_back(order[i]); }
        lead->where_group.from_vec(&order, self.sc->ctx);
    }

    /// What may carry a guard, and what a group may not hold yet. One
    /// error per member; false when it was reported.
    priv fn _member_ok(self, f: *FunctionDecl, name: string) -> bool {
        var at = f->range;
        var guard = (f->where_clause->range) if (f->has_where()) else (f->range);
        var owner = self._owner(f);

        if f->has_where() && (owner != &null) && isa::<InterfaceDecl>(owner) {
            var b = self.sc->diag->report(DiagID::SC001E, guard.start,
                "'where' is not allowed on an interface method; interfaces are zero-cost, "
                + "so a requirement cannot dispatch at run time. Use 'requires' for a "
                + "compile-time constraint");
            b.first(guard);
            b.note(DiagID::SC001N, owner->range.start, "the interface is declared here");
            b.emit();
            f->poison();
            return false;
        }
        if f->has_where() && f->is_unsafe() {
            var b = self.sc->diag->report(DiagID::SC001E, guard.start,
                f"'where' is not allowed on an 'unsafe' overload of '{name}\x27");
            b.first(guard);
            b.note(DiagID::SC001N, at.start,
                "unsafe overloads are a separate namespace, selected with 'unsafe' at the call; "
                + "they take no part in 'where' dispatch");
            b.emit();
            f->poison();
            return false;
        }
        if f->has_where() && (!f->has_body()) {
            var b = self.sc->diag->report(DiagID::SC001E, guard.start,
                f"a guarded overload of '{name}' needs a body; the guard chooses which body runs");
            b.first(guard);
            b.emit();
            f->poison();
            return false;
        }

        // eval.mdx forbids `where` on an eval fn outright, and
        // EvalUsageChecking says so; a gate here would report it twice.
        if f->is_eval() { return false; }

        var gate = "";
        if (f->abi == AbiKind::Virtual) || (f->abi == AbiKind::Override) { gate = "a 'virtual' or 'override' method"; }
        else if f->generic_params.size() > 0 { gate = "a generic function"; }
        else if decl_extension_of(static_cast::<*Decl>(f)) != &null { gate = "an extension member"; }
        else if f->is_operator     { gate = "an operator"; }
        else if self._is_ctor(f)   { gate = "a constructor"; }
        else if f->is_out_of_line() { gate = "an out-of-line definition"; }
        else if !f->has_body()     { gate = "a forward declaration"; }
        else if f->is_generator    { gate = "a generator"; }
        else if f->is_async()      { gate = "an 'async' function"; }
        else if self._has_default(f) { gate = "a default argument"; }
        else if f->is_variadic     { gate = "a variadic function"; }
        if gate.size() == 0 { return true; }

        var b = self.sc->diag->report(DiagID::SC116E, at.start,
            f"'where' dispatch on {gate} is not yet supported");
        b.first(guard);
        b.emit();
        f->poison();
        return false;
    }

    /// One function to C++, so one contract. A disagreement is reported at
    /// the later member, with a note at the first.
    priv fn _members_agree(self, members: *vec::<*FunctionDecl>, name: string) -> bool {
        var a = (*members)[0];
        for var i: usize = 1; i < members->size(); ++i {
            var b = (*members)[i];
            var what = "";
            if self._ret(a) != self._ret(b)           { what = "return type"; }
            else if a->is_const() != b->is_const()   { what = "'const self\x27"; }
            else if a->is_inline() != b->is_inline() { what = "'inline\x27"; }
            else if a->is_noreturn != b->is_noreturn { what = "'-> !\x27"; }
            else if a->abi != b->abi                 { what = "linkage"; }
            if what.size() == 0 { continue; }
            var d = self.sc->diag->report(DiagID::SC001E, b->range.start,
                f"every overload in the 'where' dispatch of '{name}' must have the same " + what
                + "; C++ sees them as one function");
            d.first(b->range);
            d.note(DiagID::SC001N, a->range.start, "the first overload of the dispatch is here");
            d.emit();
            b->poison();
            return false;
        }
        return true;
    }

    priv fn _ret(self, f: *FunctionDecl) -> *Type {
        if f->is_noreturn { return self.sc->builtin(BuiltinKind::Never); }
        if f->return_type == &null { return self.sc->builtin(BuiltinKind::Void); }
        return canon_unqual(f->return_type->canonical);
    }

    priv fn _owner(self, f: *FunctionDecl) -> *Decl {
        var dc = reinterpret_cast::<*DeclContext>(f->semantic_dc);
        if (dc == &null) || (!dc->is_type_scope()) { return &null; }
        return dc->dc_owner;
    }

    priv fn _is_ctor(self, f: *FunctionDecl) -> bool {
        if f->is_operator || (!f->is_method()) { return false; }
        var owner = self._owner(f);
        if owner == &null { return false; }
        return self._tu.decl_name(static_cast::<*Decl>(f)) == self._tu.decl_name(owner);
    }

    priv fn _has_default(self, f: *FunctionDecl) -> bool {
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if (p != &null) && (p->default_val != &null) { return true; }
        }
        return false;
    }

    // === boxes ================================================================

    priv fn _min64(self) -> i64 { return i64(-9223372036854775807) - i64(1); }
    priv fn _max64(self) -> i64 { return i64(9223372036854775807); }

    /// Each parameter's range, then each guard's box over it.
    priv fn _build_boxes(self, order: *vec::<*FunctionDecl>) {
        var f0 = (*order)[0];
        self._np = f0->params.size();
        self._dlo.clear(); self._dhi.clear(); self._dok.clear();
        for var p: usize = 0; p < self._np; ++p {
            var pd = f0->params[p];
            var t: *Type = &null;
            if (pd != &null) && (!pd->is_self) && (pd->type_ != &null) { t = self._tu.as_value(pd->type_->canonical); }
            var lo = i64(0);
            var hi = i64(0);
            var ok = false;
            if (t != &null) && self._tu.is_bool(t) {
                lo = i64(0); hi = i64(1); ok = true;
            } else if (t != &null) && self._tu.is_integer(t) {
                var bits = self._tu.int_bits(t);
                if (bits > 0) && (bits <= 64) {
                    ok = true;
                    if self._tu.is_signed_int(t) {
                        if bits == 64 { lo = self._min64(); hi = self._max64(); }
                        else {
                            var half = i64(1) << i64(bits - 1);
                            lo = i64(0) - half;
                            hi = half - i64(1);
                        }
                    } else {
                        lo = i64(0);
                        if bits >= 63 { hi = self._max64(); }   // u64 cut at i64::MAX (header)
                        else { hi = (i64(1) << i64(bits)) - i64(1); }
                    }
                }
            }
            self._dlo.push_back(lo);
            self._dhi.push_back(hi);
            self._dok.push_back(ok);
        }

        self._lo.clear(); self._hi.clear(); self._simple.clear(); self._empty.clear();
        for var m: usize = 0; m < order->size(); ++m {
            for var p: usize = 0; p < self._np; ++p {
                self._lo.push_back(self._dlo[p]);
                self._hi.push_back(self._dhi[p]);
            }
            self._simple.push_back(true);
            self._empty.push_back(false);
            var f = (*order)[m];
            if !self._narrow(m, f, f->where_clause) { self._simple[m] = false; }
        }
    }

    /// Narrow member \p m's box by \p e; false when \p e is not simple.
    priv fn _narrow(self, m: usize, f: *FunctionDecl, e0: *Expr) -> bool {
        var e = self._tu.strip_parens(e0);
        if e == &null { return false; }

        if isa::<BooleanLiteralExpr>(e) {
            if !cast::<BooleanLiteralExpr>(e)->value { self._empty[m] = true; }
            return true;
        }

        var bp = self._bool_param(f, e);
        if bp != usize(-1) { return self._clip(m, bp, i64(1), i64(1)); }

        if isa::<UnaryOperatorExpr>(e) {
            var u = cast::<UnaryOperatorExpr>(e);
            var k = u->op_token.kind;
            if (k != TokenKind::OpExclaim) && (k != TokenKind::KwNot) { return false; }
            var np = self._bool_param(f, u->operand);
            if np == usize(-1) { return false; }
            return self._clip(m, np, i64(0), i64(0));
        }

        if !isa::<BinaryOperatorExpr>(e) { return false; }
        var b = cast::<BinaryOperatorExpr>(e);
        if b->resolved_op != &null { return false; }   // a user operator: anything at all.
        var k = b->op_token.kind;
        if (k == TokenKind::OpAmpAmp) || (k == TokenKind::KwAnd) {
            var l = self._narrow(m, f, b->lhs);
            var r = self._narrow(m, f, b->rhs);
            return l && r;
        }

        // `p OP c` or `c OP p`, the second read as the first with OP flipped.
        var pi = self._int_param(f, b->lhs);
        var other = b->rhs;
        var flip = false;
        if pi == usize(-1) {
            pi = self._int_param(f, b->rhs);
            other = b->lhs;
            flip = true;
        }
        if pi == usize(-1) { return false; }
        var cv = i64(0);
        if !self._const(other, &cv) { return false; }

        if flip {
            if k == TokenKind::OpLess { k = TokenKind::OpGreater; }
            else if k == TokenKind::OpGreater { k = TokenKind::OpLess; }
            else if k == TokenKind::OpLessEqual { k = TokenKind::OpGreaterEqual; }
            else if k == TokenKind::OpGreaterEqual { k = TokenKind::OpLessEqual; }
        }

        var lo = self._dlo[pi];
        var hi = self._dhi[pi];
        if k == TokenKind::OpEqualEqual {
            return self._clip(m, pi, cv, cv);
        }
        if k == TokenKind::OpLessEqual { return self._clip(m, pi, lo, cv); }
        if k == TokenKind::OpGreaterEqual { return self._clip(m, pi, cv, hi); }
        if k == TokenKind::OpLess {
            if cv <= lo { self._empty[m] = true; return true; }
            return self._clip(m, pi, lo, cv - i64(1));
        }
        if k == TokenKind::OpGreater {
            if cv >= hi { self._empty[m] = true; return true; }
            return self._clip(m, pi, cv + i64(1), hi);
        }
        return false;
    }

    /// Intersect member \p m's interval for \p p with [lo, hi].
    priv fn _clip(self, m: usize, p: usize, lo: i64, hi: i64) -> bool {
        var at = m * self._np + p;
        if lo > self._lo[at] { self._lo[at] = lo; }
        if hi < self._hi[at] { self._hi[at] = hi; }
        if self._lo[at] > self._hi[at] { self._empty[m] = true; }
        return true;
    }

    /// \p e names one of \p f's own integer parameters: its index.
    priv fn _int_param(self, f: *FunctionDecl, e: *Expr) -> usize {
        var p = self._param_of(f, e);
        if p == usize(-1) { return p; }
        if !self._dok[p] { return usize(-1); }
        var t = self._tu.as_value(f->params[p]->type_->canonical);
        if !self._tu.is_integer(t) { return usize(-1); }
        return p;
    }

    priv fn _bool_param(self, f: *FunctionDecl, e: *Expr) -> usize {
        var p = self._param_of(f, e);
        if p == usize(-1) { return p; }
        if !self._dok[p] { return usize(-1); }
        var t = self._tu.as_value(f->params[p]->type_->canonical);
        if !self._tu.is_bool(t) { return usize(-1); }
        return p;
    }

    priv fn _param_of(self, f: *FunctionDecl, e0: *Expr) -> usize {
        var e = self._tu.strip_parens(e0);
        if (e == &null) || (!isa::<NamedIdentExpr>(e)) { return usize(-1); }
        var d = cast::<NamedIdentExpr>(e)->resolved_decl;
        if (d == &null) || (!isa::<ParamDecl>(d)) { return usize(-1); }
        var p = self._tu.param_index(f, cast::<ParamDecl>(d));
        if (p == usize(-1)) || (p >= self._np) { return usize(-1); }
        return p;
    }

    /// \p e folded to an i64 (the header's range).
    priv fn _const(self, e: *Expr, out: *i64) -> bool {
        var c = self._ce.eval_int(e);
        if (!c.ok) || c.overflow { return false; }
        var top = u64(9223372036854775807);
        if c.neg {
            if c.mag > top + u64(1) { return false; }
            if c.mag == top + u64(1) { (*out) = self._min64(); return true; }
            (*out) = i64(0) - static_cast::<i64>(c.mag);
            return true;
        }
        if c.mag > top { return false; }
        (*out) = static_cast::<i64>(c.mag);
        return true;
    }

    // === relations ============================================================

    /// Box \p b inside box \p a.
    priv fn _inside(self, a: usize, b: usize) -> bool {
        for var p: usize = 0; p < self._np; ++p {
            var ia = a * self._np + p;
            var ib = b * self._np + p;
            if (self._lo[ib] < self._lo[ia]) || (self._hi[ib] > self._hi[ia]) { return false; }
        }
        return true;
    }

    priv fn _meet(self, a: usize, b: usize) -> bool {
        for var p: usize = 0; p < self._np; ++p {
            var ia = a * self._np + p;
            var ib = b * self._np + p;
            var lo = (self._lo[ia]) if (self._lo[ia] > self._lo[ib]) else (self._lo[ib]);
            var hi = (self._hi[ia]) if (self._hi[ia] < self._hi[ib]) else (self._hi[ib]);
            if lo > hi { return false; }
        }
        return true;
    }

    /// The one parameter box \p m constrains: usize(-2) for none (the
    /// whole space), usize(-1) for more than one.
    priv fn _only_param(self, m: usize) -> usize {
        var found = usize(-2);
        for var p: usize = 0; p < self._np; ++p {
            var i = m * self._np + p;
            if (self._lo[i] == self._dlo[p]) && (self._hi[i] == self._dhi[p]) { continue; }
            if found != usize(-2) { return usize(-1); }
            found = p;
        }
        return found;
    }

    /// [lo, hi] of parameter \p p inside the union of the simple, non-empty
    /// boxes among members [0, upto) that constrain only \p p (or nothing).
    priv fn _union_covers(self, upto: usize, p: usize, lo: i64, hi: i64) -> bool {
        var cur = lo;
        while true {
            var best = cur;
            var reached = false;
            for var j: usize = 0; j < upto; ++j {
                if (!self._simple[j]) || self._empty[j] { continue; }
                var only = self._only_param(j);
                if only == usize(-2) { return true; }   // a `true` guard covers everything.
                if only != p { continue; }
                var i = j * self._np + p;
                if (self._lo[i] <= cur) && (self._hi[i] >= cur) {
                    if (!reached) || (self._hi[i] > best) { best = self._hi[i]; reached = true; }
                }
            }
            if !reached { return false; }
            if best >= hi { return true; }
            cur = best + i64(1);
        }
        return false;
    }

    /// Every value of the parameters satisfies some guard (header).
    priv fn _covers(self, order: *vec::<*FunctionDecl>) -> bool {
        var n = order->size();
        for var m: usize = 0; m < n; ++m {
            if self._simple[m] && (!self._empty[m]) && (self._only_param(m) == usize(-2)) { return true; }
        }
        for var m: usize = 0; m < n; ++m {
            if (!self._simple[m]) || self._empty[m] { continue; }
            var p = self._only_param(m);
            if p >= self._np { continue; }
            return self._union_covers(n, p, self._dlo[p], self._dhi[p]);
        }
        return false;
    }

    priv fn _warn(self, order: *vec::<*FunctionDecl>, name: string) {
        for var k: usize = 0; k < order->size(); ++k {
            if !self._simple[k] { continue; }
            var g = (*order)[k];
            var at = g->where_clause->range;
            if self._empty[k] {
                var b = self.sc->diag->report(DiagID::SC001W, at.start,
                    f"'where' guard of '{name}' never holds, so this overload is never called");
                b.first(at);
                b.emit();
                continue;
            }

            var hit = usize(-1);
            for var j: usize = 0; j < k; ++j {
                if (!self._simple[j]) || self._empty[j] { continue; }
                if self._inside(j, k) { hit = j; break; }
            }
            if hit == usize(-1) {
                var p = self._only_param(k);
                if (p < self._np) && self._union_covers(k, p, self._lo[k * self._np + p], self._hi[k * self._np + p]) {
                    // Point at the last earlier guard it meets: the one that
                    // closes the gap.
                    for var j: usize = 0; j < k; ++j {
                        if self._simple[j] && (!self._empty[j]) && self._meet(j, k) { hit = j; }
                    }
                }
            }
            if hit != usize(-1) {
                var e = (*order)[hit];
                var b = self.sc->diag->report(DiagID::SC001W, at.start,
                    f"'where' guard of '{name}' is unreachable: every value it accepts is taken by an earlier overload");
                b.first(at);
                b.note(DiagID::SC001N, e->where_clause->range.start, "this guard is tested first");
                b.emit();
                continue;
            }

            for var j: usize = 0; j < k; ++j {
                if (!self._simple[j]) || self._empty[j] { continue; }
                if (!self._meet(j, k)) || self._inside(k, j) { continue; }
                var e = (*order)[j];
                var b = self.sc->diag->report(DiagID::SC001W, at.start,
                    f"'where' guard of '{name}' overlaps an earlier one; a value both accept goes to the earlier overload");
                b.first(at);
                b.note(DiagID::SC001N, e->where_clause->range.start, "overlaps this guard, which is tested first");
                b.emit();
                break;
            }
        }
    }
}
