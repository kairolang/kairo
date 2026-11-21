/// --- The Kairo Project ------------------------- Codegen/Plan/Roots.k --- ///
///
///   EmitPlan, part: roots. Where the working set starts: the TU's own
///   declarations, the scopes its extensions are emitted in, and, for a
///   preamble, the declarations its bodies use.
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
ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "vector"

import AST::Context::DeclContext::DeclContext
import AST::DeclFacts
import AST::Kind::TypeKind::TypeKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    QualifiedType,
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Program::TopLevelKind
import AST::Node::Statements::DeclStmt
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    FixedArrayType,
    FunctionPointerType,
    NullableType,
    PointerType,
    TupleType,
}
import AST::ParamMode::ParamMode
import Codegen::Plan::Admit
import Codegen::Plan::Early
import Codegen::Plan::EmitPlan::{
    EmitPlan,
    ExtScope,
    PlanMode,
    PlanNeed,
}
import Codegen::Plan::Friends
import Codegen::Plan::Layout
import Codegen::Plan::Order
import Codegen::Plan::Visitors::HoistedLocals
import Codegen::Plan::Witness
import Codegen::Spell::Spell::Speller

extend EmitPlan {
    /// # Roots: own decls

    /// Every plannable decl the TU declares, at the strength its own kind
    /// demands: a type is defined here (Complete), a function is declared.
    /// Header mode takes only `pub` ones. Modules and visibility groups are
    /// walked through; an extension block puts its scope in the plan.
    fn _collect_own(self, dc: unsafe *DeclContext) {
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *d = *dc->dc_decls.get(i)
            if d == &null {
                continue
            }

            self._collect_own_decl(d)
        }
    }

    fn _collect_own_decl(self, d: unsafe *Decl) {
        if d->is_poisoned() {
            return
        }

        if isa<Declarations::ModuleDecl>(d) {
            self._collect_own((cast<Declarations::ModuleDecl>(d)))
            return
        }

        if isa<Declarations::VisibilityGroupDecl>(d) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(d)
            for var i: usize = 0; i < g->members.size(); ++i {
                self._collect_own_decl(g->members[i])
            }

            return
        }

        if isa<Declarations::FFIBlockDecl>(d) {
            var unsafe *g = cast<Declarations::FFIBlockDecl>(d)
            for var i: usize = 0; i < g->body.size(); ++i {
                self._collect_own_decl(g->body[i])
            }

            return
        }

        if isa<Declarations::ExtensionDecl>(d) {
            var unsafe *x = cast<Declarations::ExtensionDecl>(d)
            // A conditional block is no root of its own file: its signatures
            // may name what this file's headers do not declare. It enters a
            // plan through a use (_admit_use), in a file that declares them.
            if x->gate != &null {
                return
            }

            // A header reaches the scope through any visible member, and then
            // carries the WHOLE struct; a block with none adds no root.
            if self._mode != PlanMode::Preamble && self._hidden(d) {
                return
            }

            var visible = false
            for var i: usize = 0; i < x->methods.size(); ++i {
                var unsafe *m = x->methods[i]
                if m == &null {
                    continue
                }

                if self._mode != PlanMode::Preamble && self._hidden(m) {
                    continue
                }

                visible = true
            }

            if visible {
                self._scope_for(x, true)
            }

            self._witness_declared(d)
            return
        }

        if !self._plannable(d) {
            return
        }

        // A hidden decl another file's header names is a root of its own
        // header (_BORROWED); everything else hidden stays out.
        if self._mode != PlanMode::Preamble
            && self._hidden(d)
            && !(self._mode == PlanMode::Header && EmitPlan::_is_borrowed(d)) {
            return
        }

        if self._is_type_decl(d) {
            // A definition here means every own type is Complete; its own
            // dependencies come in through _expand.
            self._admit(d, PlanNeed::Complete)
            self._witness_declared(d)
        } else {
            self._admit(d, PlanNeed::Fwd)
            if self._mode != PlanMode::Preamble && isa<Declarations::FunctionDecl>(d) {
                self._own_sig_complete(cast<Declarations::FunctionDecl>(d))
            }
        }
    }

    /// A header or include is read by C++ code that CALLS the file's `pub`
    /// functions, and a call whose return or by-value parameter is an
    /// incomplete class is ill-formed: `lib::name()` returning `string` was
    /// "incomplete return type '::builtin::string::string'", as was a
    /// record of another Kairo module. So an own function's signature is
    /// held as a complete class's member signature is (_expand_member_sig:
    /// by value Complete, a pointer still Fwd). An object build's preamble
    /// only declares, and keeps _expand_fn's Fwd.
    fn _own_sig_complete(self, n: unsafe *Declarations::FunctionDecl) {
        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = *n->params.get(i)
            if p == &null || p->is_self {
                continue
            }

            self._admit_type(
                (if (p->is_pack && p->pack_type != &null) => (p->pack_type) else => p->type_),
                PlanNeed::Complete,
            )
        }

        self._admit_type(n->return_type, PlanNeed::Complete)
        self._admit_type(n->panic_result, PlanNeed::Complete)
    }

    /// File-scope `var`/`const`/`static`/`eval`. They parse as DeclStmts in
    /// program->items and never enter tu->dc_decls (ASTParse::_build_symbols),
    /// so the dc walk above cannot see them; without this a TU whose only
    /// definitions are globals is is_empty, and a function naming one finds no
    /// prior `extern`, which for a `const` is the difference between external
    /// and internal linkage.
    /// The `fn`s, classes and enums written in this TU's function bodies: each
    /// is an own declaration at namespace scope (Speller::is_hoisted_local),
    /// defined here whether or not a body names it. A header and an include
    /// take one only through a use -- an inline or template body that calls
    /// it, which the body walk admits.
    fn _collect_own_locals(self) {
        var hl = HoistedLocals()
        hl.run(self._cg->tu)
        for var i: usize = 0; i < hl.found.size(); ++i {
            self._collect_own_decl(hl.found[i])
        }
    }

    fn _collect_own_globals(self) {
        var unsafe *prog = self._cg->tu->program
        for var i: usize = 0; i < prog->items.size(); ++i {
            var item = *prog->items.get(i)
            if item.kind != TopLevelKind::Stmt {
                continue
            }

            var unsafe *ds = dyn_cast<DeclStmt>(item.as_stmt())
            if ds == &null || ds->decl == &null {
                continue
            }

            self._collect_own_decl(ds->decl)
        }
    }

    /// # Extension scopes

    /// The scope `x` contributes to, created on first touch; `reach` marks it
    /// reachable. Index-based: the closure below can grow _scopes.
    ///
    /// Filled COMPLETELY at creation, never from the use that touched it: with
    /// members appended per use, TU A's struct would have the three it calls
    /// and TU B's the five it calls, two definitions of one class.
    fn _scope_for(self, x: unsafe *Declarations::ExtensionDecl, reach: bool) -> usize {
        if x == &null || x->target == &null || x->target->canonical == &null {
            kairo::std::ice_fail(
                "EmitPlan: extension with an unresolved target reached codegen",
            )
        }

        var ns   = self._spell.scope_ns(x)
        var name = self._spell.ext_scope_name(x)
        for var i: usize = 0; i < self._scopes.size(); ++i {
            var *s = &self._scopes[i]
            if s->name != name || !self._same_ns_vec(s->ns, ns) {
                continue
            }

            // Same N, same struct name: it must be the same target, or two
            // targets (`a::Point`, `b::Point`) would share one struct.
            if !self._same_scope(i, x) {
                self._ice(
                    x->range,
                    f"EmitPlan: two extension targets in one namespace both spell '{name}'; the scope naming rule needs a disambiguator",
                )
            }

            if reach {
                s->reachable = true
            }

            return i
        }

        var fresh = ExtScope()
        fresh.ns   = ns
        fresh.name = name.copy()
        var unsafe *c = canon_unqual(x->target->canonical)
        if isa<RecordType>(c) {
            fresh.target = self.layout_decl(cast<RecordType>(c)->decl)
            fresh.key    = self._scope_key(cast<RecordType>(c)->decl)
        } else {
            fresh.target_ty = c
        }

        fresh.reachable = reach
        self._scopes.push_back(fresh)
        var k = self._scopes.size() - 1

        // Every block of this (N, X) lives in x's file: N is that file's
        // module path plus its module blocks.
        var unsafe *tu = Speller::tu_of(x)
        if tu == &null || tu->program == &null {
            self._ice(x->range, "EmitPlan: extension with no owning TU")
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            var item = *items->get(i)
            if item.kind != TopLevelKind::Decl {
                continue
            }

            self._fill_scope(k, item.as_decl())
        }

        if self._scopes[k].anchor == &null {
            self._ice(
                x->range,
                "EmitPlan: an extension's own file does not contain it",
            )
        }

        // A static member's signature names its types and lays none out; the
        // definition and its forwarders need the deps complete.
        //
        // EVERY member is expanded, priv included: the struct is emitted whole
        // in every TU that touches it, so a type only a priv member names must
        // be declared in a preamble whose own code never mentions it. A nested
        // type there is a dep too -- `Other::Inner` cannot be named through
        // the bare `class Other;` that Fwd gives.
        self._scope_dep(k, x->target)
        var nm = self._scopes[k].members.size()
        for var i: usize = 0; i < nm; ++i {
            var unsafe *m = self._scopes[k].members[i]
            // Each block's own target: one scope holds the blocks of every
            // specialization (`extend <> Store<bool>` beside `extend <T>
            // Store<T>`), and a member's receiver names its block's.
            self._scope_dep(k, self._scopes[k].exts[i]->target)
            self._expand_fn(m)
            self._scope_sig_dep(k, m->return_type)
            if m->panic_result != &null {
                self._scope_sig_dep(k, m->panic_result)
            }

            for var j: usize = 0; j < m->params.size(); ++j {
                var unsafe *p = m->params[j]
                if p == &null || p->is_self {
                    continue
                }

                self._scope_sig_dep(k, (if (p->is_pack && p->pack_type != &null) => (p->pack_type) else => p->type_))
            }

            if !m->is_operator || self._spell.ext_forwarder_name(m).size() == 0 {
                continue
            }

            self._scope_dep(k, m->return_type)
            if m->panic_result != &null {
                self._scope_dep(k, m->panic_result)
            }

            for var j: usize = 0; j < m->params.size(); ++j {
                var unsafe *p = m->params[j]
                if p == &null || p->is_self || p->mode != ParamMode::Value {
                    continue
                }

                self._scope_dep(k, p->type_)
            }
        }

        return k
    }

    /// Walk `cand` (modules, visibility groups) for every extend block of
    /// scope `k`, adding its members in source order.
    fn _fill_scope(self, k: usize, cand: unsafe *Decl) {
        if cand == &null || cand->is_poisoned() {
            return
        }

        if isa<Declarations::VisibilityGroupDecl>(cand) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(cand)
            for var i: usize = 0; i < g->members.size(); ++i {
                self._fill_scope(k, g->members[i])
            }

            return
        }

        if isa<Declarations::FFIBlockDecl>(cand) {
            var unsafe *g = cast<Declarations::FFIBlockDecl>(cand)
            for var i: usize = 0; i < g->body.size(); ++i {
                self._fill_scope(k, g->body[i])
            }

            return
        }

        if isa<Declarations::ModuleDecl>(cand) {
            var unsafe *dc = unsafe (cast<Declarations::ModuleDecl>(cand) as unsafe *DeclContext)
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                self._fill_scope(k, *dc->dc_decls.get(i))
            }

            return
        }

        var unsafe *x = dyn_cast<Declarations::ExtensionDecl>(cand)
        if x == &null || x->target == &null || x->target->canonical == &null {
            return
        }

        if !self._same_scope(k, x) {
            return
        }

        var ns = self._spell.scope_ns(x)
        if !self._same_ns_vec(self._scopes[k].ns, ns) {
            return
        }

        // A conditional block's scope is its own (Speller::ext_scope_name):
        // one target in one namespace can have several structs.
        if self._spell.ext_scope_name(x) != self._scopes[k].name {
            return
        }

        if self._scopes[k].anchor == &null {
            self._scopes[k].anchor = x
        }

        for var i: usize = 0; i < x->methods.size(); ++i {
            var unsafe *m = x->methods[i]
            if m == &null || m->is_poisoned() {
                continue
            }

            var unsafe *c  = cast<Declarations::FunctionDecl>(Speller::rep(m))
            var        dup = false
            for var j: usize = 0; j < self._scopes[k].members.size(); ++j {
                if self._scopes[k].members[j] == c {
                    dup = true
                    break
                }
            }

            if dup {
                continue
            }

            self._scopes[k].members.push_back(c)
            self._scopes[k].exts.push_back(x)
        }
    }

    /// `x`'s target is scope `k`'s: the same layout decl for a record, the
    /// same canonical type for a builtin. Namespace is the caller's to compare.
    fn _same_scope(self, k: usize, x: unsafe *Declarations::ExtensionDecl) -> bool {
        var unsafe *c = canon_unqual(x->target->canonical)
        var        *s = &self._scopes[k]
        if isa<RecordType>(c) {
            return s->target != &null && self._scope_key(cast<RecordType>(c)->decl) == s->key
        }

        return s->target == &null && s->target_ty == c
    }

    /// A by-value record `t` is a Complete dependency of scope `k`, recorded
    /// as the tier-1 entry that defines it (an outermost type, a primary).
    fn _scope_dep(self, k: usize, t: unsafe *Type) {
        if t == &null || t->canonical == &null {
            return
        }

        var unsafe *c = canon_unqual(t->canonical)
        if isa<NullableType>(c) {
            self._scope_dep(k, self._nullable_record(c))
            return
        }

        if !isa<RecordType>(c) {
            return
        }

        var unsafe *d = self.layout_decl(cast<RecordType>(c)->decl)
        if d == &null || DeclFacts::decl_is_imported(d) || isa<Declarations::InterfaceDecl>(d) {
            return
        }

        self._admit_type(t, PlanNeed::Complete)
        self._scope_add_dep(k, self._outermost_type(d))
    }

    /// The record a canonical `T?` is to C++ (NullableType::lowered). None means
    /// NullableTypeLowering never saw it: the same ICE Speller raises.
    fn _nullable_record(self, c: unsafe *Type) -> unsafe *Type {
        var unsafe *lw = cast<NullableType>(c)->lowered
        if lw == &null {
            self._ice(
                c->range,
                "EmitPlan: T? reached codegen with no lowered record; NullableTypeLowering must run first",
            )
        }

        return lw
    }

    /// A NESTED record anywhere in a member signature `t` -- behind pointers,
    /// references, arrays, as a generic argument -- makes its outermost owner a
    /// Complete dep of scope `k`: a member type is named only through a
    /// complete enclosing class.
    fn _scope_sig_dep(self, k: usize, t: unsafe *Type) {
        if t == &null {
            return
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        match c->kind {
            case TypeKind::QualifiedType {
                self._scope_sig_dep(k, cast<QualifiedType>(c)->inner)
            } case TypeKind::PointerType {
                self._scope_sig_dep(k, cast<PointerType>(c)->pointee)
            } case TypeKind::CXXLValueRefType {
                self._scope_sig_dep(k, cast<CXXLValueRefType>(c)->referee)
            } case TypeKind::CXXRValueRefType {
                self._scope_sig_dep(k, cast<CXXRValueRefType>(c)->referee)
            } case TypeKind::NullableType {
                self._scope_sig_dep(k, self._nullable_record(c))
            } case TypeKind::FixedArrayType {
                self._scope_sig_dep(k, cast<FixedArrayType>(c)->element)
            } case TypeKind::TupleType {
                var unsafe *tp = cast<TupleType>(c)
                for var i: usize = 0; i < tp->elements.size(); ++i {
                    self._scope_sig_dep(k, *tp->elements.get(i))
                }
            } case TypeKind::FunctionPointerType {
                var unsafe *fp = cast<FunctionPointerType>(c)
                for var i: usize = 0; i < fp->params.size(); ++i {
                    self._scope_sig_dep(k, *fp->params.get(i))
                }

                self._scope_sig_dep(k, fp->return_type)
            } case TypeKind::RecordType {
                var unsafe *r = cast<RecordType>(c)
                for var i: usize = 0; i < r->args.size(); ++i {
                    self._scope_sig_dep(k, *r->args.get(i))
                }

                if r->outer != &null {
                    self._scope_sig_dep(k, r->outer)
                }

                var unsafe *d = self.layout_decl(r->decl)
                if d == &null
                    || DeclFacts::decl_is_imported(d)
                    || isa<Declarations::InterfaceDecl>(d) {
                    return
                }

                var unsafe *outer = self._outermost_type(d)
                // An ADT's layout record sits in the enum's scope, but it IS the
                // enum, not a type nested in it.
                if outer == d || self.adt_record(outer) == d {
                    return
                }

                self._admit(outer, PlanNeed::Complete)
                self._scope_add_dep(k, outer)
            } default { }
        }
    }

    fn _scope_add_dep(self, k: usize, d: unsafe *Decl) {
        for var i: usize = 0; i < self._scopes[k].deps.size(); ++i {
            if self._scopes[k].deps[i] == d {
                return
            }
        }

        self._scopes[k].deps.push_back(d)
    }

    /// # Roots: uses (preamble only)

    fn _collect_uses(self) {
        self.run(self._cg->tu)
    }

    /// Walk visible_bodies() at body strengths, both modes: a preamble's foreign
    /// template and inline bodies, a header's own.
    fn _walk_visible(self) {
        // Every template and inline body visible here is this TU's body too:
        // EmitIR emits each one into this TU (emit_tu), so what it names has to
        // be in this preamble -- `alignof(YieldPromise<T>)`, `p->cur`, `return Suspend {}`
        // -- at the body strengths, exactly as this TU's own bodies are walked.
        // To a fixed point: a walked body can make another type Complete, and
        // that type's template bodies become visible in turn. In a header the
        // same walk is what declares the priv helpers and types an own inline
        // body names: _collect_own left them out, _admit does not.
        var walked      = cxx::std::vector<unsafe *Declarations::FunctionDecl>()
        var walked_vars = cxx::std::vector<unsafe *Declarations::VariableDecl>()
        var progressed  = true
        while progressed {
            progressed = false
            var vis = self.visible_bodies()
            for var i: usize = 0; i < vis.size(); ++i {
                var seen = false
                for var k: usize = 0; k < walked.size(); ++k {
                    if walked[k] == vis[i] {
                        seen = true
                        break
                    }
                }

                if seen {
                    continue
                }

                walked.push_back(vis[i])
                self._walk_body(vis[i])
                progressed = true
            }

            // An eval binding's definition is interface too (Compiler/Spec/Eval.md#eval-bindings):
            // what its initializer names -- the eval fn it calls, the eval
            // constant it reads -- is this TU's to declare and define.
            var vv = self.visible_eval_vars()
            for var i: usize = 0; i < vv.size(); ++i {
                var seen = false
                for var k: usize = 0; k < walked_vars.size(); ++k {
                    if walked_vars[k] == vv[i] {
                        seen = true
                        break
                    }
                }

                if seen {
                    continue
                }

                walked_vars.push_back(vv[i])
                self.dispatch_decl(unsafe (vv[i] as unsafe *Decl))
                progressed = true
            }
        }
    }

    /// The eval bindings (namespace scope) whose `inline constexpr`
    /// definitions this TU writes beside its own (Compiler/Spec/Eval.md#eval-bindings), chosen as
    /// visible_bodies chooses: the foreign ones a preamble declares, a header's
    /// own, both for an include. An importer cannot read an `extern const` in
    /// a constant expression, so the definition, like a consteval body, is part
    /// of the interface.
    fn visible_eval_vars(self) -> cxx::std::vector<unsafe *Declarations::VariableDecl> {
        if self._mode == PlanMode::Include {
            return self.include_eval_vars()
        }

        return self._eval_vars(self._mode == PlanMode::Header)
    }

    fn include_eval_vars(self) -> cxx::std::vector<unsafe *Declarations::VariableDecl> {
        var out = self._eval_vars(false)
        var own = self._eval_vars(true)
        for var i: usize = 0; i < own.size(); ++i {
            out.push_back(own[i])
        }

        return out
    }

    /// In dependency order: a constant expression reads another constant only
    /// once it is defined, and declarations across files have no order of
    /// their own. A cycle is not a constant at all; C++ reports it.
    fn _eval_vars(self, want_own: bool) -> cxx::std::vector<unsafe *Declarations::VariableDecl> {
        var pick = cxx::std::vector<unsafe *Declarations::VariableDecl>()
        for var i: usize = 0; i < self._set.size(); ++i {
            var unsafe *v = dyn_cast<Declarations::VariableDecl>(self._set[i])
            if v == &null || !v->is_eval() || v->init == &null || v->is_poisoned() {
                continue
            }

            if Speller::fid_of(v) == self._home != want_own {
                continue
            }

            pick.push_back(v)
        }

        var out   = cxx::std::vector<unsafe *Declarations::VariableDecl>()
        var state = cxx::std::vector<u8>() // 0 new, 1 on the path, 2 placed; parallel to pick.
        for var i: usize = 0; i < pick.size(); ++i {
            state.push_back(0 as u8)
        }

        for var i: usize = 0; i < pick.size(); ++i {
            self._place_eval_var(i, unsafe &pick, unsafe &state, unsafe &out)
        }

        return out
    }

    fn _place_eval_var(self,
                       i:     usize,
                       pick:  unsafe *cxx::std::vector<unsafe *Declarations::VariableDecl>,
                       state: unsafe *cxx::std::vector<u8>,
                       out:   unsafe *cxx::std::vector<unsafe *Declarations::VariableDecl>) {
        if (*state)[i] != (0 as u8) {
            return
        }

        (*state)[i] = (1)
        // What the initializer reads, through the eval fns it calls too: `eval
        // A = f()` with f returning B needs B defined first, though A's
        // initializer never names it.
        var unsafe *me = unsafe ((*pick)[i] as unsafe *Decl)
        self._early_needs(me)
        var seeds = cxx::std::vector<unsafe *Decl>()
        for var r: usize = 0; r < self._en.size(); ++r {
            if self._en[r].item == me && self._en[r].kind == (0 as u8) {
                seeds.push_back(self._en[r].val)
            }
        }

        var refs = cxx::std::vector<unsafe *Decl>()
        self._early_close(seeds, 0, unsafe &refs)
        for var r: usize = 0; r < refs.size(); ++r {
            for var k: usize = 0; k < pick->size(); ++k {
                if ((*pick)[k]) == refs[r] {
                    self._place_eval_var(k, pick, state, out)
                }
            }
        }

        (*state)[i] = (2)
        out->push_back((*pick)[i])
    }
}
