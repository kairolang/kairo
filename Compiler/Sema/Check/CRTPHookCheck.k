/// --- The Kairo Project ------------------- Sema/Check/CRTPHookCheck.k --- ///
///
///   \brief Warn when a derived class's method looks like the CRTP hook its
///          base calls through `self.dyn()` but takes different parameter
///          types, so the base's call silently runs the base's own hook
///          (SC278W).
///
///   \detail
///     A generic base reaches the class that derives it through a method
///     like `fn dyn(self) -> unsafe *D { return &self as *D }` and calls
///     the derived class's version of a method on it (generics.mdx,
///     "Mixins"). Methods with different parameters merge into one overload
///     set (classes-inheritance.mdx), so a derived method that was meant to
///     replace the hook but spells a parameter differently is a second
///     overload, and `self.dyn()->hook(x)` keeps picking the base's:
///
///         // base:    fn traverse_match_case(self, mc: unsafe *MatchCase)
///         // derived: fn traverse_match_case(self, mc: *MatchCase?)
///
///     The trigger, precisely:
///
///       - a DYN method is a method of a generic class with no parameter but
///         `self` that returns a pointer (`*`, `unsafe *`, either nullable)
///         to one of that class's type parameters;
///       - a HOOK is a name and an argument count called on a dyn method's
///         result (`X.dyn()->name(a, b)`, `dyn()->name(...)`) in a body of
///         the class or of any class it derives, directly or through others;
///       - the derived class (C) declares a method M with a hook's name and
///         argument count, and some base of C (not C) declares a method of
///         that name and arity, but none of them with M's C++ parameter
///         types, parameter modes and `self` constness. C++ types, because
///         a dyn call in a `: type` base is resolved by clang per instance:
///         `*T` and `unsafe *T` are both `T*` there, so the derived method
///         does hide the base's, while `*T?` is a Nullable and does not. A
///         base method whose parameters depend on a type parameter is not
///         compared (it is not claimed to differ), nor is a generic M.
///
///     A base that is not reached as `B<C>` for the class itself (or for a
///     type parameter of a class in between, the mixin case) has no dyn
///     path to C and is skipped.
///
///     The note points at the base's hook and at one call through dyn.
///     When every differing parameter differs only in pointer safety,
///     nullability or `const` (the same pointee), the fix-it rewrites M's
///     parameter types to the base's. `@no_warn(SC278W)` on M keeps a
///     deliberate second overload.
///
///   Phase: CHECK (after ExprTyper; reads resolved signatures; bodies only
///          syntactically, for the dyn calls)
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

import AST::Context::ASTContext::ASTContext
import AST::DeclFacts::{
    decl_is_imported,
    decl_is_instance,
    decl_pattern,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_has_const,
    canon_quals,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl,
    FunctionDecl,
    ParamDecl,
}
import AST::Node::Expressions::CallExpr
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Types::{
    GenericParamType,
    NullableType,
    PointerType,
}
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil

/// One `R()->name(args)` in a body, where `R` is a zero-argument call of a
/// method named `via`: a dyn call when `via` is a dyn method's name.
pub struct CRTPCall {
    pub var via:   string
    pub var name:  string
    pub var arity: usize
    pub var at:    SourceRange
}

///
/// \class CRTPCallScan
/// \brief Every `R()->name(args)` call shape in the bodies it walks.
///
pub class CRTPCallScan derives RecursiveASTVisitor<CRTPCallScan> {
    pub var ctx:   unsafe *ASTContext = &null
    pub var calls: cxx::std::vector<CRTPCall>

    pub fn scan(self, m: unsafe *FunctionDecl) {
        if m->body_block != &null {
            self.dyn()->traverse_block(m->body_block)
        } else if m->body_expr != &null {
            self.dyn()->dispatch_expr(m->body_expr)
        }
    }

    fn visit_call_expr(self, n: *CallExpr) -> bool {
        var unsafe *ch = dyn_cast<ChainExpr>(n->callee)
        if ch == &null || ch->steps.size() != 1 || self.ctx == &null {
            return true
        }

        var unsafe *st = ch->steps.get(0)
        if st->name == &null || st->access_kind != ChainExpr::AccessKind::Arrow {
            return true
        }

        var unsafe *inner = dyn_cast<CallExpr>(ch->base)
        if inner == &null || inner->args.size() != 0 {
            return true
        }

        var via = ""
        var unsafe *ic = dyn_cast<ChainExpr>(inner->callee)
        if ic != &null && ic->steps.size() > 0 {
            var unsafe *last = ic->steps.get(ic->steps.size() - 1)
            if last->name != &null {
                via = self.ctx->get_spelling(last->name->name)
            }
        } else {
            var unsafe *id = dyn_cast<NamedIdentExpr>(inner->callee)
            if id != &null {
                via = self.ctx->get_spelling(id->name)
            }
        }

        if via.empty() {
            return true
        }

        var c = CRTPCall{}
        c.via   = via
        c.name  = self.ctx->get_spelling(st->name->name)
        c.arity = n->args.size()
        c.at    = n->range
        self.calls.push_back(c)
        return true
    }
}

pub class CRTPHookCheck derives RecursiveASTVisitor<CRTPHookCheck> {
    pub var  sc:  unsafe *SemaContext
    priv var _tu: TypeUtil
    /// Per class pattern, the call shapes of its bodies: a pattern is the
    /// base of many classes in one TU (every visitor derives the RAV), and
    /// its bodies are scanned once.
    priv var _scanned: cxx::std::vector<unsafe *ClassDecl>
    priv var _calls:   cxx::std::vector<cxx::std::vector<CRTPCall>>

    fn CRTPHookCheck(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self._tu = TypeUtil(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::TypesResolved)
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            var item = *items->get(i)
            if item.get_kind() == TopLevelKind::Decl {
                self.dyn()->dispatch_decl(item.as_decl())
            }
        }
    }

    /// Bodies are not this pass's: only class declarations are read, and a
    /// class nested in a function body has no CRTP base worth the walk.
    fn traverse_function_decl(self, n: unsafe *FunctionDecl) -> unsafe *FunctionDecl {
        return n
    }

    fn visit_class_decl(self, n: *ClassDecl) -> bool {
        var unsafe *self_d = unsafe (n as unsafe *Decl)
        if n->is_poisoned() || decl_is_instance(self_d) || decl_is_imported(self_d) {
            return true
        }

        var bases = cxx::std::vector<unsafe *ClassDecl>()
        self._bases(unsafe (n as unsafe *ClassDecl), unsafe (n as unsafe *ClassDecl), unsafe &bases, 0)
        if bases.empty() {
            return true
        }

        // The dyn methods C can call: its own and every base's.
        var dyns = cxx::std::vector<string>()
        self._dyn_names(unsafe (n as unsafe *ClassDecl), unsafe &dyns)
        for var i: usize = 0; i < bases.size(); ++i {
            self._dyn_names(bases[i], unsafe &dyns)
        }

        if dyns.empty() {
            return true
        }

        for var i: usize = 0; i < n->methods.size(); ++i {
            var unsafe *m = n->methods[i]
            if m == &null || m->is_poisoned() || (!m->is_method()) || m->is_operator
                || m->generic_params.size() > 0 || self._dependent_sig(m) {
                continue
            }

            var name  = self._name(unsafe (m as unsafe *Decl))
            var arity = m->params.size() - 1
            var call  = CRTPCall{}
            if !self._hook_call(unsafe (n as unsafe *ClassDecl), &bases, &dyns, name, arity, &call) {
                continue
            }

            self._check(m, &bases, name, arity, &call)
        }

        return true
    }

    /// # the class's bases

    /// The class patterns \p cd derives, transitively, each once, reached as
    /// a CRTP base of \p root: an edge `B<X>` whose arguments name \p root
    /// or a type parameter (a mixin passing its own along). A non-generic
    /// base is kept too: it may declare the hook a generic base above it
    /// calls.
    priv fn _bases(self,
                   root: unsafe *ClassDecl,
                   cd:   unsafe *ClassDecl,
                   out:  unsafe *cxx::std::vector<unsafe *ClassDecl>,
                   depth: u32) {
        if cd == &null || depth > 32 {
            return
        }

        for var i: usize = 0; i < cd->derives_list.size(); ++i {
            var unsafe *e = cd->derives_list.get(i)
            if e == &null || e->base == &null || e->base->canonical == &null {
                continue
            }

            var unsafe *rt = dyn_cast<RecordType>(canon_unqual(e->base->canonical))
            if rt == &null {
                continue
            }

            var unsafe *bd = dyn_cast<ClassDecl>(decl_pattern(rt->decl))
            if bd == &null || bd == root || decl_is_imported(unsafe (bd as unsafe *Decl)) {
                continue
            }

            if rt->args.size() > 0 && !self._crtp_args(root, rt) {
                continue
            }

            var have = false
            for var k: usize = 0; k < out->size(); ++k {
                if (*out)[k] == bd {
                    have = true
                    break
                }
            }

            if have {
                continue
            }

            out->push_back(bd)
            self._bases(root, bd, out, depth + 1)
        }
    }

    /// Some argument of the base instance \p rt is \p root itself or a type
    /// parameter: the shape a dyn method can cast `self` down to.
    priv fn _crtp_args(self, root: unsafe *ClassDecl, rt: unsafe *RecordType) -> bool {
        var unsafe *want = NameLookup::representative(unsafe (root as unsafe *Decl))
        for var i: usize = 0; i < rt->args.size(); ++i {
            var unsafe *a = canon_unqual(rt->args[i])
            if a == &null {
                continue
            }

            if isa<GenericParamType>(a) {
                return true
            }

            var unsafe *ar = dyn_cast<RecordType>(a)
            if ar != &null && NameLookup::representative(decl_pattern(ar->decl)) == want {
                return true
            }
        }

        return false
    }

    /// # dyn methods and hooks

    /// The names of \p cd's dyn methods, added to \p out.
    priv fn _dyn_names(self, cd: unsafe *ClassDecl, out: unsafe *cxx::std::vector<string>) {
        if cd->generic_params.size() == 0 {
            return
        }

        for var i: usize = 0; i < cd->methods.size(); ++i {
            var unsafe *m = cd->methods[i]
            if m == &null || (!m->is_method()) || m->params.size() != 1 || m->return_type == &null {
                continue
            }

            var unsafe *rt = canon_unqual(m->return_type->canonical)
            var unsafe *nt = dyn_cast<NullableType>(rt)
            if nt != &null {
                rt = canon_unqual(nt->inner)
            }

            var unsafe *pt = dyn_cast<PointerType>(rt)
            if pt == &null || (!isa<GenericParamType>(canon_unqual(pt->pointee))) {
                continue
            }

            out->push_back(self._name(unsafe (m as unsafe *Decl)))
        }
    }

    /// A call of \p name with \p arity arguments through a dyn method, in a
    /// body of \p cd or of one of \p bases; the first one found into \p out.
    priv fn _hook_call(self,
                       cd:         unsafe *ClassDecl,
                       bases:      *cxx::std::vector<unsafe *ClassDecl>,
                       dyns:       *cxx::std::vector<string>,
                       const name: string,
                       arity:      usize,
                       out:        *CRTPCall) -> bool {
        if self._hook_in(cd, dyns, name, arity, out) {
            return true
        }

        for var i: usize = 0; i < bases->size(); ++i {
            if self._hook_in((*bases)[i], dyns, name, arity, out) {
                return true
            }
        }

        return false
    }

    priv fn _hook_in(self,
                     cd:         unsafe *ClassDecl,
                     dyns:       *cxx::std::vector<string>,
                     const name: string,
                     arity:      usize,
                     out:        *CRTPCall) -> bool {
        var unsafe *calls = self._calls_of(cd)
        for var i: usize = 0; i < calls->size(); ++i {
            var *c = &(*calls)[i]
            if c->name != name || c->arity != arity {
                continue
            }

            for var k: usize = 0; k < dyns->size(); ++k {
                if (*dyns)[k] == c->via {
                    (*out) = *c
                    return true
                }
            }
        }

        return false
    }

    /// The call shapes in \p cd's method bodies, scanned once per pattern.
    priv fn _calls_of(self, cd: unsafe *ClassDecl) -> unsafe *cxx::std::vector<CRTPCall> {
        for var i: usize = 0; i < self._scanned.size(); ++i {
            if self._scanned[i] == cd {
                return unsafe &self._calls[i]
            }
        }

        var s = CRTPCallScan()
        s.ctx = NameLookup::ctx_of(unsafe (cd as unsafe *Decl))
        for var i: usize = 0; i < cd->methods.size(); ++i {
            var unsafe *m = cd->methods[i]
            if m == &null {
                continue
            }

            s.scan(m)
        }

        self._scanned.push_back(cd)
        self._calls.push_back(cxx::std::move(s.calls))
        return unsafe &self._calls[self._calls.size() - 1]
    }

    /// # the comparison

    /// \p m (of the class) has a hook's name and arity: warn unless a base's
    /// method of that name and arity takes the same parameters.
    priv fn _check(self,
                   m:          unsafe *FunctionDecl,
                   bases:      *cxx::std::vector<unsafe *ClassDecl>,
                   const name: string,
                   arity:      usize,
                   call:       *CRTPCall) {
        var pick: unsafe *FunctionDecl = &null
        var any = false
        for var i: usize = 0; i < bases->size(); ++i {
            var unsafe *bd = (*bases)[i]
            for var j: usize = 0; j < bd->methods.size(); ++j {
                var unsafe *b = bd->methods[j]
                if b == &null || (!b->is_method()) || b->is_operator || b->generic_params.size() > 0
                    || b->params.size() != arity + 1
                    || self._name(unsafe (b as unsafe *Decl)) != name {
                    continue
                }

                // A dependent base parameter is not compared: claiming it
                // differs would warn on a hook that does match per instance.
                if self._dependent_sig(b) || self._same(m, b) {
                    return
                }

                any = true
                if pick == &null || self._qual_only(m, b) && (!self._qual_only(m, pick)) {
                    pick = b
                }
            }
        }

        if !any || pick == &null {
            return
        }

        var owner = self._owner_name(pick)
        var mname = self._owner_name(m)
        var why   = "the parameter types differ"
        if self._same_params(m, pick) {
            why = if (self._self_const(pick)) => ("the base's takes 'const self' and this one 'self'")
                  else => "the base's takes 'self' and this one 'const self'"
        }

        var w = self.sc->diag->report(
            DiagID::SC278W,
            m->name.range.start,
            f"'{mname}::{name}' does not replace '{owner}::{name}', which '{owner}' calls through '{call->via}()': {why}, so that call still runs '{owner}::{name}'",
        )

        w.first(m->name.range, f"a second overload of '{name}', not the hook")
        for var i: usize = 1; i < m->params.size(); ++i {
            var unsafe *mp = m->params[i]
            var unsafe *bp = pick->params[i]
            if (!self._cxx_same(mp->type_->canonical, bp->type_->canonical)) || mp->mode != bp->mode {
                w.second(mp->type_->range, f"'{self._tu.str(bp->type_->canonical)}' in the base")
            }
        }

        if self._self_const(m) != self._self_const(pick) {
            w.second(m->params[0]->range, if (self._self_const(pick)) => ("the base's hook takes 'const self'")
                                          else => "the base's hook takes 'self'")
        }

        if self._qual_only(m, pick) {
            for var i: usize = 1; i < m->params.size(); ++i {
                var unsafe *mp = m->params[i]
                var unsafe *bp = pick->params[i]
                if self._cxx_same(mp->type_->canonical, bp->type_->canonical) {
                    continue
                }

                var core = self._core_spelling(mp->type_)
                w.fix(mp->type_->range, self._spell_like(bp->type_->canonical, core), "take the base hook's parameter type")
            }
        }

        w.note(DiagCode(DiagID::SC278N), pick->name.range.start,
            f"the hook '{owner}' calls; to replace it, take exactly its parameters")
        w.note(DiagCode(DiagID::SC278N), call->at.start,
            f"called here through '{call->via}()'; with both overloads visible it picks '{owner}::{name}'")
        w.emit()
    }

    /// \p a and \p b take the same parameters after `self`, in the same
    /// modes, with the same `self` constness: \p a overrides or hides \p b.
    priv fn _same(self, a: unsafe *FunctionDecl, b: unsafe *FunctionDecl) -> bool {
        if self._self_const(a) != self._self_const(b) {
            return false
        }

        for var i: usize = 1; i < a->params.size(); ++i {
            var unsafe *pa = a->params[i]
            var unsafe *pb = b->params[i]
            if pa == &null || pb == &null || pa->type_ == &null || pb->type_ == &null {
                return true // unresolved: never claim a difference.
            }

            if pa->mode != pb->mode || (!self._cxx_same(pa->type_->canonical, pb->type_->canonical)) {
                return false
            }
        }

        return true
    }

    /// The parameters after `self` agree in C++ type and mode.
    priv fn _same_params(self, a: unsafe *FunctionDecl, b: unsafe *FunctionDecl) -> bool {
        for var i: usize = 1; i < a->params.size(); ++i {
            var unsafe *pa = a->params[i]
            var unsafe *pb = b->params[i]
            if pa->mode != pb->mode || (!self._cxx_same(pa->type_->canonical, pb->type_->canonical)) {
                return false
            }
        }

        return true
    }

    /// \p a and \p b are one C++ parameter type: equal canonicals, or
    /// pointers that differ only in safety (`*T` and `unsafe *T` are both
    /// `T*`, so the derived one does hide the base's in C++), level by
    /// level with the pointees' qualifiers. A parameter's own top-level
    /// `const` is no part of a C++ signature. `*T?` is a Nullable in C++,
    /// never a `T*`: it stays apart (RedeclMerge::_cxx_same, the same rule).
    priv fn _cxx_same(self, a_in: unsafe *Type, b_in: unsafe *Type) -> bool {
        var unsafe *a = canon_unqual(a_in)
        var unsafe *b = canon_unqual(b_in)
        var        n  = 0u32
        while a != &null && b != &null && n < 16 {
            n = n + 1
            if a == b {
                return true
            }

            var unsafe *pa = dyn_cast<PointerType>(a)
            var unsafe *pb = dyn_cast<PointerType>(b)
            if pa == &null || pb == &null || pa->pointee == &null || pb->pointee == &null {
                return false
            }

            if canon_quals(pa->pointee) != canon_quals(pb->pointee) {
                return false
            }

            a = canon_unqual(pa->pointee)
            b = canon_unqual(pb->pointee)
        }

        return false
    }

    /// Every differing parameter of \p a and \p b reaches the same pointee
    /// through the same number of pointers: only safety, nullability or
    /// `const` differ, and a rewrite of the type to the base's is the fix.
    priv fn _qual_only(self, a: unsafe *FunctionDecl, b: unsafe *FunctionDecl) -> bool {
        var differs = false
        for var i: usize = 1; i < a->params.size(); ++i {
            var unsafe *ta = a->params[i]->type_->canonical
            var unsafe *tb = b->params[i]->type_->canonical
            if self._cxx_same(ta, tb) {
                continue
            }

            if a->params[i]->mode != b->params[i]->mode {
                return false
            }

            differs = true
            var da: u32 = 0
            var db: u32 = 0
            var unsafe *ca = self._core(ta, &da)
            var unsafe *cb = self._core(tb, &db)
            if ca == &null || ca != cb || da != db || da == 0 {
                return false
            }
        }

        return differs && self._self_const(a) == self._self_const(b)
    }

    /// \p t with pointers, nullables and cv stripped; \p depth counts the
    /// pointers.
    priv fn _core(self, t: unsafe *Type, depth: *u32) -> unsafe *Type {
        var unsafe *u = canon_unqual(t)
        var        n  = 0u32
        while u != &null && n < 16 {
            n = n + 1
            var unsafe *nt = dyn_cast<NullableType>(u)
            if nt != &null {
                u = canon_unqual(nt->inner)
                continue
            }

            var unsafe *pt = dyn_cast<PointerType>(u)
            if pt != &null {
                (*depth) = (*depth) + 1
                u = canon_unqual(pt->pointee)
                continue
            }

            break
        }

        return u
    }

    /// The spelling of the innermost written type of \p written (`MatchCase`
    /// in `*MatchCase?`): the name as the derived file spells it, which the
    /// base's spelling (`Statements::MatchCase`) may not resolve to here.
    priv fn _core_spelling(self, written: unsafe *Type) -> string {
        var unsafe *w = written
        var        n  = 0u32
        while w != &null && n < 16 {
            n = n + 1
            var unsafe *nt = dyn_cast<NullableType>(w)
            if nt != &null && nt->inner != &null {
                w = nt->inner
                continue
            }

            var unsafe *pt = dyn_cast<PointerType>(w)
            if pt != &null && pt->pointee != &null {
                w = pt->pointee
                continue
            }

            break
        }

        var unsafe *ctx = self.sc->ctx
        if w == &null || ctx == &null || (!w->range.is_valid()) {
            return self._tu.str(canon_unqual(self._core(written->canonical, &n)))
        }

        var text = ctx->get_spelling(w->range)
        // A written `const T` pointee keeps its qualifier in the text; the
        // base's constness is spelled by _spell_like.
        if text.starts_with("const ") {
            return ctx->get_spelling(SourceRange(w->range.start.with_offset(6), w->range.end))
        }

        return text
    }

    /// The canonical \p t spelled around \p core (its innermost record).
    priv fn _spell_like(self, t: unsafe *Type, const core: string) -> string {
        var unsafe *u = canon_unqual(t)
        var unsafe *nt = dyn_cast<NullableType>(u)
        if nt != &null {
            return self._spell_like(nt->inner, core) + "?"
        }

        var unsafe *pt = dyn_cast<PointerType>(u)
        if pt != &null {
            var pre = if (pt->is_unsafe) => ("unsafe *") else => "*"
            if canon_has_const(pt->pointee) {
                pre = pre + "const "
            }

            var inner = self._spell_like(canon_unqual(pt->pointee), core)
            if isa<NullableType>(canon_unqual(pt->pointee)) {
                return pre + "(" + inner + ")"
            }

            return pre + inner
        }

        return core
    }

    /// # small facts

    priv fn _self_const(self, f: unsafe *FunctionDecl) -> bool {
        var unsafe *p = f->params[0]
        return p != &null && p->type_ != &null && p->type_->canonical != &null
            && canon_has_const(p->type_->canonical)
    }

    /// Some parameter type of \p f is unresolved or names a type parameter.
    priv fn _dependent_sig(self, f: unsafe *FunctionDecl) -> bool {
        for var i: usize = 1; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null || p->type_ == &null || p->type_->canonical == &null || p->is_pack {
                return true
            }

            if p->type_->canonical->is_dependent() {
                return true
            }
        }

        return false
    }

    priv fn _name(self, d: unsafe *Decl) -> string {
        return self._tu.decl_name(d)
    }

    priv fn _owner_name(self, f: unsafe *FunctionDecl) -> string {
        var unsafe *dc = f->semantic_dc
        if dc == &null || dc->dc_owner == &null {
            return "?"
        }

        return self._tu.decl_name(dc->dc_owner)
    }
}
