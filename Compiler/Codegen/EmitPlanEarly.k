/// --- The Kairo Project ---------------------- Codegen/EmitPlanEarly.k --- ///
///
///   EmitPlan, part: early items and bodies. The eval bindings and values
///   defined ahead of the declarations that read them
///   (Compiler/Spec/Eval.md#value-nodes), the list of foreign bodies a TU
///   emits, and what a body's walk admits.
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

import AST::ASTSupport::FrozenList
import AST::Context::DeclContext::DeclContextKind
import AST::Context::SymbolTable::OverloadCell
import AST::DeclFacts
import AST::Kind::DeclKind::DeclKind
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::LowerTargets
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
import AST::Node::Types::{
    CXXLValueRefType, CXXRValueRefType, FixedArrayType, FunctionPointerType, NullableType,
    PointerType,      TupleType,
}
import Codegen::Emit::Spell::Speller
import Codegen::EmitPlan::{
    BigStr,
    EarlyNeed,
    EmitPlan,
    PlanMode,
    PlanNeed,
}
import Codegen::EmitPlanAdmit
import Codegen::EmitPlanLayout
import Codegen::EmitPlanRoots
import Codegen::PlanVisitors::EarlyNeeds

extend EmitPlan {
    /// # Early items (Compiler/Spec/Eval.md#value-nodes)

    /// Which compile-time items a declaration's type needs defined ahead of it
    /// (EmitPlan::early), and the order edges that put them in tier 1. Seeds:
    /// the computed values in the type of every record this plan defines
    /// (fields, bases, method signatures, nested types), of every function it
    /// declares and of every namespace-scope variable. Closed over what each
    /// item reads. A record follows every item its own types reach; an item
    /// follows the records its definition needs complete, and a binding every
    /// item it evaluates (a body only the items it evaluates at its definition:
    /// what it merely calls is defined by the time anything evaluates it, and
    /// mutual recursion stays free of cycles).
    fn _early(self) {
        for var i: usize = 0; i < self._set.size(); ++i {
            var unsafe *d    = self._set[i]
            var        seeds = cxx::std::vector<unsafe *Decl>()
            var        rec   = self._is_type_decl(d)
            if rec {
                if self._need[i] != PlanNeed::Complete {
                    continue
                }

                self._decl_type_items(d, unsafe &seeds)
            } else if isa<Declarations::FunctionDecl>(d) {
                var unsafe *f = cast<Declarations::FunctionDecl>(d)
                for var p: usize = 0; p < f->params.size(); ++p {
                    var unsafe *pd = f->params[p]
                    if pd != &null && !pd->is_self {
                        self._type_items(pd->type_, unsafe &seeds)
                    }
                }

                self._type_items(f->return_type, unsafe &seeds)
            } else if isa<Declarations::VariableDecl>(d) {
                self._type_items(
                    cast<Declarations::VariableDecl>(d)->type_,
                    unsafe &seeds,
                )
            }

            if seeds.size() == 0 {
                continue
            }

            var cl = cxx::std::vector<unsafe *Decl>()
            self._early_close(seeds, 0, unsafe &cl)
            for var k: usize = 0; k < cl.size(); ++k {
                EarlyNeeds::_once(&self.early, cl[k])
                if rec {
                    self._eo_add(d, cl[k])
                }
            }
        }

        for var k: usize = 0; k < self.early.size(); ++k {
            var unsafe *x = self.early[k]
            self._early_needs(x)
            var defs = cxx::std::vector<unsafe *Decl>()
            var want = if (isa<Declarations::VariableDecl>(x)) => (0 as u8) else => (1)
            for var i: usize = 0; i < self._en.size(); ++i {
                if self._en[i].item != x {
                    continue
                }

                if self._en[i].kind == (2 as u8) {
                    var unsafe *r = self._layout_key(self._en[i].val)
                    if r != &null && r != x {
                        var at = self._index_of(r)
                        if at != usize::MAX && self._need[at] == PlanNeed::Complete {
                            self._eo_add(x, r)
                        }
                    }
                } else if self._en[i].kind == want {
                    defs.push_back(self._en[i].val)
                }
            }

            var cl = cxx::std::vector<unsafe *Decl>()
            self._early_close(defs, 0, unsafe &cl)
            for var i: usize = 0; i < cl.size(); ++i {
                if cl[i] != x {
                    self._eo_add(x, cl[i])
                }
            }

            // An early fn x names whose signature computes from other items is
            // declared only once those are defined (InterfaceEmitter): x's
            // definition follows them, so that declaration precedes it.
            for var i: usize = 0; i < self._en.size(); ++i {
                if self._en[i].item != x || self._en[i].kind != (0 as u8) {
                    continue
                }

                var unsafe *y = dyn_cast<Declarations::FunctionDecl>(
                    self._en[i].val,
                )

                if y == &null || (unsafe (y as unsafe *Decl)) == x {
                    continue
                }

                var sig = cxx::std::vector<unsafe *Decl>()
                self.sig_items(y, unsafe &sig)
                for var si: usize = 0; si < sig.size(); ++si {
                    if sig[si] != x {
                        self._eo_add(x, sig[si])
                    }
                }
            }
        }
    }

    /// The early items `f`'s own signature computes from (`eval fn f(a: [i32;
    /// g(1)])`, a computed return type): C++ evaluates them where f is
    /// DECLARED, so f is declared only after they are defined. Never f itself.
    fn sig_items(self,
                 f:   unsafe *Declarations::FunctionDecl,
                 out: unsafe *cxx::std::vector<unsafe *Decl>) {
        if f == &null {
            return
        }

        var all = cxx::std::vector<unsafe *Decl>()
        for var p: usize = 0; p < f->params.size(); ++p {
            var unsafe *pd = f->params[p]
            if pd != &null && !pd->is_self {
                self._type_items(pd->type_, unsafe &all)
            }
        }

        self._type_items(f->return_type, unsafe &all)
        for var i: usize = 0; i < all.size(); ++i {
            if all[i] != (unsafe (f as unsafe *Decl)) && self.is_early(all[i]) {
                EarlyNeeds::_once(&*out, all[i])
            }
        }
    }

    /// `x`'s EarlyNeeds, computed once into the _en_ tables.
    fn _early_needs(self, x: unsafe *Decl) {
        for var i: usize = 0; i < self._en_done.size(); ++i {
            if self._en_done[i] == x {
                return
            }
        }

        self._en_done.push_back(x)
        var        n  = EarlyNeeds()
        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(x)
        if f != &null {
            // A member's definition is out of line: its class is complete first.
            n.named(x)
            n.dispatch_decl(x)
        }

        var unsafe *v = dyn_cast<Declarations::VariableDecl>(x)
        if v != &null {
            n.rec_type(v->type_)
            if v->init != &null {
                n.dispatch_expr(v->init)
            }
        }

        for var i: usize = 0; i < n.items.size(); ++i {
            if n.items[i] == x {
                continue
            }

            self._en_add(x, 0 as u8, n.items[i])
        }

        for var i: usize = 0; i < n.const_items.size(); ++i {
            if n.const_items[i] == x {
                continue
            }

            self._en_add(x, 1 as u8, n.const_items[i])
        }

        for var i: usize = 0; i < n.recs.size(); ++i {
            self._en_add(x, 2 as u8, n.recs[i])
        }
    }

    fn _en_add(self, item: unsafe *Decl, kind: u8, val: unsafe *Decl) {
        var r = EarlyNeed{}
        r.item = item
        r.kind = kind
        r.val  = val
        self._en.push_back(r)
    }

    /// `seeds` and every item they read (kind 0), transitively, into `out`.
    fn _early_close(self,
                    const seeds: cxx::std::vector<unsafe *Decl>,
                    kind:        u8,
                    out:         unsafe *cxx::std::vector<unsafe *Decl>) {
        for var i: usize = 0; i < seeds.size(); ++i {
            EarlyNeeds::_once(&*out, (seeds)[i])
        }

        for var k: usize = 0; k < out->size(); ++k {
            var unsafe *it = (*out)[k]
            self._early_needs(it)
            for var i: usize = 0; i < self._en.size(); ++i {
                if self._en[i].item == it && self._en[i].kind == kind {
                    EarlyNeeds::_once(&*out, self._en[i].val)
                }
            }
        }
    }

    /// The items the types written in record `d`'s definition compute from:
    /// fields, bases, method signatures, nested records' (they are defined
    /// inside it).
    fn _decl_type_items(self, d: unsafe *Decl, out: unsafe *cxx::std::vector<unsafe *Decl>) {
        var unsafe *rec = self.adt_record(d)
        var fields:  unsafe *FrozenList<unsafe *Declarations::FieldDecl>    = &null
        var methods: unsafe *FrozenList<unsafe *Declarations::FunctionDecl> = &null
        if isa<Declarations::ClassDecl>(rec) {
            var unsafe *c = cast<Declarations::ClassDecl>(rec)
            fields  = unsafe &c->fields
            methods = unsafe &c->methods
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                var unsafe *e = c->derives_list.get(i)
                if e != &null {
                    self._type_items(e->base, out)
                }
            }
        } else if isa<Declarations::StructDecl>(rec) {
            fields  = unsafe &cast<Declarations::StructDecl>(rec)->fields
            methods = unsafe &cast<Declarations::StructDecl>(rec)->methods
        } else if isa<Declarations::UnionDecl>(rec) {
            fields  = unsafe &cast<Declarations::UnionDecl>(rec)->fields
            methods = unsafe &cast<Declarations::UnionDecl>(rec)->methods
        }

        if fields != &null {
            for var i: usize = 0; i < fields->size(); ++i {
                var unsafe *f = (*fields)[i]
                if f != &null {
                    self._type_items(f->type_, out)
                }
            }
        }

        if methods != &null {
            for var i: usize = 0; i < methods->size(); ++i {
                var unsafe *m = (*methods)[i]
                if m == &null {
                    continue
                }

                for var p: usize = 0; p < m->params.size(); ++p {
                    var unsafe *pd = m->params[p]
                    if pd != &null && !pd->is_self {
                        self._type_items(pd->type_, out)
                    }
                }

                self._type_items(m->return_type, out)
            }
        }

        // A generic record's value predicates C++ cannot evaluate on the
        // template head are its body's static_asserts (InterfaceEmitter::
        // _record_def): the items they name are declared, and defined, ahead of
        // the template, as a computed field type's are. EvalUsageChecking::
        // _check_record has refused an item that needs the record back.
        // An ADT enum's clause is the enum's, not its layout record's.
        var unsafe *rq = DeclFacts::decl_requires_clause(d)
        if rq == &null {
            rq = DeclFacts::decl_requires_clause(rec)
        }

        if Speller::template_params(rec).size() > 0 || Speller::template_params(d).size() > 0 {
            var vps = cxx::std::vector<unsafe *Expr>()
            Speller::value_predicates(rq, unsafe &vps)
            for var i: usize = 0; i < vps.size(); ++i {
                var n = EarlyNeeds()
                n.dispatch_expr(vps[i])
                for var k: usize = 0; k < n.items.size(); ++k {
                    EarlyNeeds::_once(&*out, n.items[k])
                }
            }
        }

        var unsafe *dc = Speller::dc_of(rec)
        if dc == &null {
            return
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *nd = *dc->dc_decls.get(i)
            if nd == &null || !self._is_type_decl(nd) {
                continue
            }

            if isa<Declarations::UnionDecl>(nd) && cast<Declarations::UnionDecl>(nd)->is_anonymous {
                continue
            }

            self._decl_type_items(Speller::rep(nd), out)
        }
    }

    /// The items computed values in `t` name.
    fn _type_items(self, t: unsafe *Type, out: unsafe *cxx::std::vector<unsafe *Decl>) {
        if t == &null {
            return
        }

        var n = EarlyNeeds()
        self._type_items_walk(t, unsafe &n, 0)
        for var i: usize = 0; i < n.items.size(); ++i {
            EarlyNeeds::_once(&*out, n.items[i])
        }
    }

    /// _type_items' walk: EarlyNeeds::rec_type on `t`, and on every type
    /// written inside it, through pointers, references and arguments too. A
    /// computed value behind a pointer (`*Widget<Pt(2, 3)>`) is evaluated
    /// where the declaration is written all the same, though its
    /// record is not needed complete -- only the items are read from `n`.
    fn _type_items_walk(self, t: unsafe *Type, n: unsafe *EarlyNeeds, depth: u32) {
        if t == &null || depth > (16 as u32) {
            return
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        var d1 = depth + (1 as u32)
        match c->kind {
            case TypeKind::QualifiedType {
                self._type_items_walk(cast<QualifiedType>(c)->inner, n, d1)
            } case TypeKind::PointerType {
                self._type_items_walk(cast<PointerType>(c)->pointee, n, d1)
            } case TypeKind::CXXLValueRefType {
                self._type_items_walk(cast<CXXLValueRefType>(c)->referee, n, d1)
            } case TypeKind::CXXRValueRefType {
                self._type_items_walk(cast<CXXRValueRefType>(c)->referee, n, d1)
            } case TypeKind::FunctionPointerType {
                var unsafe *fp = cast<FunctionPointerType>(c)
                for var i: usize = 0; i < fp->params.size(); ++i {
                    self._type_items_walk(*fp->params.get(i), n, d1)
                }

                self._type_items_walk(fp->return_type, n, d1)
            } case TypeKind::RecordType {
                n->rec_type(c)
                var unsafe *r = cast<RecordType>(c)
                for var i: usize = 0; i < r->args.size(); ++i {
                    self._type_items_walk(*r->args.get(i), n, d1)
                }
            } default {
                n->rec_type(c)
            }
        }
    }

    fn _eo_add(self, who: unsafe *Decl, dep: unsafe *Decl) {
        if who == &null || dep == &null || who == dep {
            return
        }

        if self._eo_has(who, dep) {
            return
        }

        self._eo_who.push_back(who)
        self._eo_dep.push_back(dep)
    }

    fn _eo_has(self, who: unsafe *Decl, dep: unsafe *Decl) -> bool {
        for var i: usize = 0; i < self._eo_who.size(); ++i {
            if self._eo_who[i] == who && self._eo_dep[i] == dep {
                return true
            }
        }

        return false
    }

    /// The tier-1 decl whose definition lays out record `d`: its primary for
    /// an instance, its outermost record for a nested one.
    fn _layout_key(self, d: unsafe *Decl) -> unsafe *Decl {
        var unsafe *c = Speller::rep(d)
        if c == &null {
            return &null
        }

        if DeclFacts::decl_is_instance(c) {
            var unsafe *e = self._cg->instances->entry_of(c)
            if e == &null {
                return &null
            }

            c = Speller::rep(e->primary)
            if c == &null {
                return &null
            }
        }

        if !self._is_type_decl(c) {
            return &null
        }

        return self._outermost_type(c)
    }

    /// `d` (a defining link) is defined in tier 1 as an early item.
    fn is_early(self, d: unsafe *Decl) -> bool {
        for var i: usize = 0; i < self.early.size(); ++i {
            if self.early[i] == d {
                return true
            }
        }

        return false
    }

    /// THE list of foreign bodies this TU emits, beside its own (which EmitIR
    /// walks off the program): every template and `inline` definition visible
    /// here, once each, as the defining link. EmitIR emits exactly this list and
    /// _walk_visible walks exactly this list, so what is planned and what is
    /// emitted cannot drift.
    ///
    /// In Header mode the same rule picks the OWN bodies instead: a header is
    /// the interface for C++ consumers and for nothing else, so it carries
    /// exactly what an importing Kairo TU would emit from this module (the
    /// foreign ones arrive through the headers it includes).
    ///
    /// The rule is C++'s template model: a template's definition must be
    /// visible in every TU that can instantiate it, and Kairo cannot list every
    /// instantiation -- clang makes some on its own (a coroutine promise,
    /// `await_suspend<coroutine_handle<...>>`, std::sort calling a Kairo
    /// comparator). So, wherever the owner is held Complete:
    ///
    ///   - every member body of a class template (members of its nested
    ///     records included -- they are templated by the enclosing one);
    ///   - every member TEMPLATE of any class, template or not;
    ///   - every free function template the plan declares;
    ///   - every generic extension member (its own or its extension's params).
    ///
    /// And `inline` bodies, by the same rule for a different reason: `inline`
    /// puts a body in the interface, so importers compile it themselves.
    ///
    ///   - every `inline` member of every record held Complete -- ALL of them,
    ///     never pruned by Kairo-visible references, because Kairo never sees
    ///     clang's own calls (`await_ready`, `initial_suspend`, ...);
    ///   - every `inline` free function or extension member the plan declares,
    ///     at any strength.
    ///
    /// Read off _set rather than this TU's roots, so it is transitive: a
    /// `priv inline` helper that an inline body calls is admitted by the walk
    /// below and its body joins the list on the next pass. That one matters --
    /// clang emits an inline definition only in objects that use it, so the
    /// helper's own object may well not hold it.
    ///
    /// Cheap because of `extern template`: a registry instance is still
    /// compiled once, in its home TU (InterfaceEmitter's tier 3 declares it
    /// `extern` everywhere else, which stops implicit instantiation of its
    /// members there). The bodies emitted everywhere are parsed everywhere but
    /// only instantiated for the instances Kairo never saw. Those `extern
    /// template` lines are NOT redundant with this; removing them would compile
    /// every known instance in every TU that uses it.
    fn visible_bodies(self) -> cxx::std::vector<unsafe *Declarations::FunctionDecl> {
        // Preamble: foreign only (own bodies are emitted off the program).
        // Header: own only.
        // Include: both. The host is a C++ TU that includes nothing else of
        // Kairo's, and it compiles foo's templates and inline functions itself;
        // _walk_visible walks the same list, so whatever they name is planned.
        if self._mode == PlanMode::Include {
            return self.include_bodies()
        }

        return self._bodies(self._mode == PlanMode::Header)
    }

    /// The foreign bodies, then the own ones: what an Include plan carries.
    fn include_bodies(self) -> cxx::std::vector<unsafe *Declarations::FunctionDecl> {
        var out = self._bodies(false)
        var own = self._bodies(true)
        for var i: usize = 0; i < own.size(); ++i {
            out.push_back(own[i])
        }

        return out
    }

    fn _bodies(self, want_own: bool) -> cxx::std::vector<unsafe *Declarations::FunctionDecl> {
        var out = cxx::std::vector<unsafe *Declarations::FunctionDecl>()
        for var i: usize = 0; i < self._set.size(); ++i {
            var unsafe *d = self._set[i]
            if Speller::fid_of(d) == self._home != want_own {
                continue
            }

            if self._is_type_decl(d) {
                if self._need[i] != PlanNeed::Complete {
                    continue
                }

                self._visible_record_bodies(d, false, unsafe &out)
                continue
            }

            if d->kind != DeclKind::FunctionDecl {
                continue
            }

            if Speller::template_params(d).size() == 0
                && (!cast<Declarations::FunctionDecl>(d)->is_inline())
                && !cast<Declarations::FunctionDecl>(d)->is_eval() {
                continue
            }

            self._push_body(cast<Declarations::FunctionDecl>(d), &out)
        }

        // Extension members are never in _set: their scope declares them, and a
        // preamble defines every scope it touches.
        for var i: usize = 0; i < self._scopes.size(); ++i {
            var *sc = &self._scopes[i]
            for var k: usize = 0; k < sc->members.size(); ++k {
                var unsafe *m = sc->members[k]
                if m == &null {
                    continue
                }

                // A conditional block's members are nobody's own: the file
                // that wrote the block compiles a body only when it uses the
                // member, as every other file does, and a header never
                // carries one.
                var unsafe *mx = DeclFacts::decl_extension_of(
                    unsafe (m as unsafe *Decl),
                )

                var own = Speller::fid_of(m) == self._home
                if mx != &null && mx->gate != &null {
                    own = false
                }

                if own != want_own {
                    continue
                }

                if Speller::template_params(unsafe (m as unsafe *Decl)).size() == 0
                    && !m->is_inline()
                    && !m->is_eval() {
                    continue
                }

                self._push_body(m, &out)
            }
        }

        return out
    }

    /// `d`'s member bodies that are part of its interface: all of them under a
    /// class template (`in_template`), only its member templates and `inline`
    /// members otherwise. Nested records recurse, as EmitIR::_record_bodies does.
    fn _visible_record_bodies(
        self,
        d:           unsafe *Decl,
        in_template: bool,
        out:         unsafe *cxx::std::vector<unsafe *Declarations::FunctionDecl>,
    ) {
        var templ = in_template || DeclFacts::decl_generic_params(d).size() > 0
        var methods = DeclFacts::decl_methods(d)
        for var i: usize = 0; i < methods.size(); ++i {
            var unsafe *m = methods[i]
            if m == &null {
                continue
            }

            // Neither template nor inline: linked from its own TU.
            if !templ && m->generic_params.size() == 0 && !m->is_inline() && !m->is_eval() {
                continue
            }

            self._push_body(m, &*out)
        }

        var unsafe *dc = Speller::dc_of(d)
        if dc == &null {
            return
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *nd = *dc->dc_decls.get(i)
            if nd == &null {
                continue
            }

            if isa<Declarations::ClassDecl>(nd)
                || isa<Declarations::StructDecl>(nd)
                || isa<Declarations::UnionDecl>(nd) {
                self._visible_record_bodies(nd, templ, out)
            }
        }
    }

    /// The DEFINING link of `f` -- an in-class declaration whose body is out of
    /// line is in the member list, the body is on the chain -- once. Nothing
    /// without a block body: there is nothing to make visible.
    fn _push_body(self,
                  f:          unsafe *Declarations::FunctionDecl,
                  @inout out: cxx::std::vector<unsafe *Declarations::FunctionDecl>) {
        var unsafe *def = f
        if !def->has_body() {
            var unsafe *d = def->definition()
            if d == &null || d->is_poisoned() {
                return
            }

            def = d
        }

        if def->is_poisoned() || def->body_kind != Declarations::FnBodyKind::Block {
            return
        }

        for var i: usize = 0; i < out.size(); ++i {
            if (out)[i] == def {
                return
            }
        }

        out.push_back(def)
    }

    /// One visible body, walked as this TU's own bodies are. An extension
    /// member's receiver is emitted as its first parameter, so the extension's
    /// target is laid out here.
    fn _walk_body(self, f: unsafe *Declarations::FunctionDecl) {
        var outer = self._in_body
        self._in_body = true
        var unsafe *x = DeclFacts::decl_extension_of(f)
        if x != &null && x->target != &null {
            self._admit_type(x->target, PlanNeed::Complete)
        }

        self.dispatch_decl(f)
        self._in_body = outer
    }

    /// A compile-time literal's bytes, `n` of them at `p`: one past the
    /// inline limit is recorded for its named definition, once per content
    /// (the name is the content's, so equal bytes are one definition).
    fn note_eval_str(self, p: kairo::std::ConstPtr<u8>, n: usize) {
        if n <= LowerTargets::eval_str_inline_max() {
            return
        }

        self._note_str(p, n, false)
    }

    /// A string literal of the two-word library, `n` bytes at `p`: its
    /// object (LowerTargets::lit_str) is defined once per content, whatever
    /// its length.
    fn note_lit_str(self, p: kairo::std::ConstPtr<u8>, n: usize) {
        self._note_str(p, n, true)
    }

    priv fn _note_str(self, p: kairo::std::ConstPtr<u8>, n: usize, header: bool) {
        var h = LowerTargets::eval_str_hash(p, n)
        for var i: usize = 0; i < self.big_strs.size(); ++i {
            if self.big_strs[i].hash == h
                && self.big_strs[i].len == n
                && self.big_strs[i].header == header {
                return
            }
        }

        var b = BigStr{}
        b.bytes  = p
        b.len    = n
        b.hash   = h
        b.header = header
        self.big_strs.push_back(b)
    }

    /// A use site. A member of a type (method, field, static, nested type)
    /// needs its OWNER complete: C++ cannot look into an incomplete class.
    /// A free function or a type needs a declaration.
    fn _admit_use(self, d: unsafe *Decl) {
        if d == &null {
            return
        }

        var unsafe *owner = self._member_owner(d)
        if owner != &null {
            self._admit(owner, PlanNeed::Complete)
            return
        }

        self._admit(d, PlanNeed::Fwd)
    }

    fn _admit_cell(self, cell: unsafe *OverloadCell) {
        if cell == &null {
            return
        }

        for var i: usize = 0; i < cell->size(); ++i {
            self._admit_use(cell->get(i))
        }
    }

    /// The object of a member step: `t` itself, or what it points at. C++
    /// looks the member up in that class, so it is complete.
    fn _admit_receiver(self, t: unsafe *Type) {
        if t == &null {
            return
        }

        var unsafe *c = canon_unqual(
            if (t->canonical != &null) => (t->canonical) else => t,
        )

        if c != &null && isa<PointerType>(c) {
            c = canon_unqual(cast<PointerType>(c)->pointee)
        }

        if c != &null && isa<RecordType>(c) {
            self._admit_type(c, PlanNeed::Complete)
        }
    }

    /// `t` a pointer to a class with bases: that class complete (see
    /// visit_expr). Anything else is left as its shape admits it.
    fn _admit_derived_pointee(self, t: unsafe *Type) {
        if t == &null {
            return
        }

        var unsafe *c = canon_unqual(
            if (t->canonical != &null) => (t->canonical) else => t,
        )

        if c == &null || !isa<PointerType>(c) {
            return
        }

        var unsafe *p = canon_unqual(cast<PointerType>(c)->pointee)
        if p == &null || !isa<RecordType>(p) {
            return
        }

        var unsafe *cd = dyn_cast<Declarations::ClassDecl>(
            Speller::rep(cast<RecordType>(p)->decl),
        )

        if cd != &null && cd->has_bases() {
            self._admit_type(p, PlanNeed::Complete)
        }
    }

    /// `t` is a tuple by value: the record TupleRecords made for one (a
    /// TupleType too, though none is canonical after T).
    fn is_tuple_type(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = canon_unqual(
            if (t->canonical != &null) => (t->canonical) else => t,
        )

        if c == &null {
            return false
        }

        if isa<TupleType>(c) {
            return true
        }

        if !isa<RecordType>(c) {
            return false
        }

        // The arity is the pattern's (TupleRecords), never an instance's.
        var unsafe *sd = dyn_cast<Declarations::StructDecl>(
            self.layout_decl(cast<RecordType>(c)->decl),
        )

        return sd != &null && sd->tuple_arity > 0
    }

    /// Every record `t` reaches through pointers, fields, method results and
    /// generic arguments, each complete (see _admit_instance, O36b). Once per
    /// record per plan: _duck_seen.
    fn _duck_reach(self, t: unsafe *Type, depth: u32) {
        if t == &null || depth > 64 {
            return
        }

        var unsafe *c = canon_unqual(
            if (t->canonical != &null) => (t->canonical) else => t,
        )

        if c == &null {
            return
        }

        match c->kind {
            case TypeKind::PointerType {
                self._duck_reach(cast<PointerType>(c)->pointee, depth + 1)
                return
            } case TypeKind::CXXLValueRefType {
                self._duck_reach(cast<CXXLValueRefType>(c)->referee, depth + 1)
                return
            } case TypeKind::CXXRValueRefType {
                self._duck_reach(cast<CXXRValueRefType>(c)->referee, depth + 1)
                return
            } case TypeKind::NullableType {
                self._duck_reach(self._nullable_record(c), depth + 1)
                return
            } case TypeKind::FixedArrayType {
                self._duck_reach(cast<FixedArrayType>(c)->element, depth + 1)
                return
            }

            // A record falls out of the switch to the walk below; Stage 1 has no
            // `break` out of a switch, so the default arm tests for it instead.
            default {
                if c->kind != TypeKind::RecordType {
                    return
                }
            }
        }

        var unsafe *r = cast<RecordType>(c)
        var unsafe *d = Speller::rep(r->decl)
        if d == &null {
            return
        }

        for var i: usize = 0; i < self._duck_seen.size(); ++i {
            if self._duck_seen[i] == d {
                return
            }
        }

        self._duck_seen.push_back(d)
        self._admit_type(c, PlanNeed::Complete)
        for var i: usize = 0; i < r->args.size(); ++i {
            self._duck_reach(*r->args.get(i), depth + 1)
        }

        if DeclFacts::decl_is_imported(d) {
            return
        }

        var unsafe *rec = self.adt_record(d)
        if rec == &null {
            return
        }

        var fields  = DeclFacts::decl_fields(rec)
        var methods = DeclFacts::decl_methods(rec)
        for var i: usize = 0; i < fields.size(); ++i {
            var unsafe *f = fields[i]
            if f != &null {
                self._duck_reach(f->type_, depth + 1)
            }
        }

        for var i: usize = 0; i < methods.size(); ++i {
            var unsafe *m = methods[i]
            if m != &null {
                self._duck_reach(m->return_type, depth + 1)
            }
        }
    }

    /// The type whose scope holds `d`, or null for a namespace-scope decl.
    fn _member_owner(self, d: unsafe *Decl) -> unsafe *Decl {
        var unsafe *dc = d->semantic_dc
        if dc == &null {
            return &null
        }

        if !dc->is_type_scope() {
            return &null
        }

        if dc->dc_kind == DeclContextKind::Extension { // its scope's static member, not the target's.
            return &null
        }

        return dc->dc_owner
    }
}
