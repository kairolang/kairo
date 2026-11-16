/// --- The Kairo Project -------------------- Codegen/EmitPlanFriends.k --- ///
///
///   EmitPlan, part: friends and borrowed declarations. The hidden foreign
///   declarations another header names (_BORROWED), and a record's friends
///   (FileFriends): the other declarations of its file that reach its
///   non-public members.
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
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::DeclFacts
import AST::Kind::TypeKind::TypeKind
import AST::Mixin::Annotation::VisibilityKind
import AST::Node::Base::{
    Decl,
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
    CXXLValueRefType, CXXRValueRefType, FixedArrayType, FunctionPointerType, NullableType,
    PointerType,      TupleType,
}
import AST::VisibilityFacts::{
    default_visibility_of,
    is_operator_fn,
}
import Codegen::Emit::Spell::{
    Speller,
    VIS_NONE,
    VIS_PRIV,
    VIS_PROT,
    VIS_PUB,
}
import Codegen::EmitPlan::{
    EmitPlan,
    ExtScope,
    FileFriends,
    PlanMode,
    PlanNeed,
    _BORROWED,
}
import Codegen::EmitPlanAdmit
import Codegen::EmitPlanLayout
import Codegen::EmitPlanOrder
import Codegen::EmitPlanWitness
import Codegen::PlanVisitors::{
    GlobalInitReach,
    HoistedLocals,
}
import std::io

extend EmitPlan {
    /// # Hidden decls another header names (_BORROWED)

    pub static fn clear_borrowed() {
        _BORROWED.clear()
    }

    /// After run() of a Header plan: every foreign function or global it
    /// admitted that its home's header leaves out is recorded for that home
    /// (_BORROWED). True when one was new: the home's plan then walks one
    /// more body, which may name another file's hidden decl in turn, so the
    /// driver repeats over every header until nothing is added.
    pub fn note_borrowed(self) -> bool {
        var added = false
        if self._mode != PlanMode::Header {
            return added
        }

        for var i: usize = 0; i < self.entries.size(); ++i {
            var *e = &self.entries[i]
            if e->own
                || e->decl == &null
                || e->scope != &null
                || e->witness != &null
                || e->inst != &null
                || e->eval_item != &null {
                continue
            }

            if (!isa<Declarations::FunctionDecl>(e->decl))
                && (!isa<Declarations::VariableDecl>(e->decl)) {
                continue
            }

            if !self._hidden(e->decl) || EmitPlan::_is_borrowed(e->decl) {
                continue
            }

            _BORROWED.push_back(e->decl)
            added = true
        }

        return added
    }

    static fn _is_borrowed(d: unsafe *Decl) -> bool {
        var unsafe *r = Speller::rep(d)
        for var i: usize = 0; i < _BORROWED.size(); ++i {
            if _BORROWED[i] == d || _BORROWED[i] == r {
                return true
            }
        }

        return false
    }

    /// The TU has nothing to define: no entry of its own at any tier and no
    /// instantiation homed here. A property of the PLAN, not of the file's
    /// bytes -- a file of comments or of `pub import` lines is as empty as a
    /// zero-byte one. An empty TU gets no C++, no clang run, no object and no
    /// header. True for a TU with no program; asked before run(), it is no
    /// verdict (a debug build ICEs).
    pub fn is_empty(self) -> bool {
        eval if defined!(DEBUG) {
            if !self._ran {
                kairo::std::ice_fail(
                    r"EmitPlan::is_empty before run(): not run is not empty",
                )
            }
        }

        return self._empty
    }

    /// Every extension scope written in \p d's OWN file, for the definition's
    /// `friend struct` lines, in plan order. Usually one; `module Geo { extend
    /// Point {...} }` beside a file-scope `extend Point` is two scopes in two
    /// namespaces, and both are friends under invariant 18 -- the set is still
    /// closed at the file.
    fn friend_scopes_of(self, d: unsafe *Decl, @inout out: cxx::std::vector<unsafe *ExtScope>) {
        var unsafe *c   = self.layout_decl(d)
        var unsafe *key = self._scope_key(d)
        for var i: usize = 0; i < self._scopes.size(); ++i {
            var unsafe *s = unsafe &self._scopes[i]
            if s->target == &null || s->key != key {
                continue
            }

            if Speller::fid_of(unsafe (s->anchor as unsafe *Decl)) != Speller::fid_of(
                c,
            ) {
                continue
            }

            // In source order, not plan order: two TUs touch the scopes in the
            // order their own code does, and the record's text must not care.
            var at = out.size()
            while at > 0 && (out)[at - 1]->anchor->range.start.id > s->anchor->range.start.id {
                at -= 1
            }

            out.push_back(s)
            var k = out.size() - 1
            while k > at {
                (out)[k] = (out)[k - 1]
                k -= 1
            }

            (out)[at] = s
        }
    }

    /// # File friends

    /// The record has a member C++ will see non-public (Speller::cxx_access).
    /// A compiler-made one never counts: only the record's own members call
    /// it. A function of the record's declaration, so of its file.
    fn needs_friends(self, d_in: unsafe *Decl) -> bool {
        var unsafe *d = Speller::rep(d_in)
        if d == &null
            || !(isa<Declarations::ClassDecl>(d)
                || isa<Declarations::StructDecl>(d)
                || isa<Declarations::UnionDecl>(d)) {
            return false
        }

        var fields:  FrozenList<unsafe *Declarations::FieldDecl>
        var methods: FrozenList<unsafe *Declarations::FunctionDecl>
        if isa<Declarations::ClassDecl>(d) {
            // A `derives priv` / `prot` edge narrows the inherited names with
            // `private:` / `protected:` usings (InterfaceEmitter::_edge_narrowing),
            // which the file must still reach through d.
            var unsafe *cd = cast<Declarations::ClassDecl>(d)
            for var i: usize = 0; i < cd->derives_list.size(); ++i {
                var unsafe *e = cd->derives_list.get(i)
                if e != &null && (e->visibility == VIS_PRIV() || e->visibility == VIS_PROT()) {
                    return true
                }
            }
        }

        if isa<Declarations::ClassDecl>(d) {
            fields  = cast<Declarations::ClassDecl>(d)->fields
            methods = cast<Declarations::ClassDecl>(d)->methods
        } else if isa<Declarations::UnionDecl>(d) {
            fields  = cast<Declarations::UnionDecl>(d)->fields
            methods = cast<Declarations::UnionDecl>(d)->methods
        } else {
            fields  = cast<Declarations::StructDecl>(d)->fields
            methods = cast<Declarations::StructDecl>(d)->methods
        }

        for var i: usize = 0; i < fields.size(); ++i {
            var unsafe *f = fields[i]
            if f == &null || f->is_implicit {
                continue
            }

            if self._spell.cxx_access(f) != VIS_PUB() {
                return true
            }
        }

        for var i: usize = 0; i < methods.size(); ++i {
            var unsafe *m = methods[i]
            if m == &null || m->is_implicit {
                continue
            }

            if self._spell.cxx_access(m) != VIS_PUB() || self._included_private(m) {
                return true
            }
        }

        var unsafe *dc = Speller::dc_of(d)
        if dc == &null {
            return false
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *nd = *dc->dc_decls.get(i)
            if nd == &null || nd->is_implicit {
                continue
            }

            if !self._is_type_decl(nd) && !isa<Declarations::TypeAliasDecl>(nd) {
                continue
            }

            if self._spell.cxx_access(nd) != VIS_PUB() || self._included_private(nd) {
                return true
            }
        }

        return false
    }

    /// \p d has no visibility written and is `priv` by default, so what C++
    /// includes (a header, a kcc `#include "x.k"` stream) writes it
    /// `private:` (InterfaceEmitter::_cxx_vis) though cxx_access, which is
    /// the module's own object's view, reads it public. The record's file
    /// must still reach it there: a `pub inline` or generic function of the
    /// file that calls it is compiled in the includer's TU.
    priv fn _included_private(self, d: unsafe *Decl) -> bool {
        if self.mode() == PlanMode::Preamble || d == &null || d->is_implicit || is_operator_fn(d) {
            return false
        }

        if self._spell.cxx_vis(d) != VIS_NONE() {
            return false
        }

        return default_visibility_of(d) == VisibilityKind::Private
    }

    /// Record \p d's friends (FileFriends), from \p d's file's declarations.
    /// Coarse on purpose: everything of the file that may name a member Kairo
    /// lets it name, whether it does or not, so no walk of any body -- which
    /// another TU may not have lowered -- decides the text.
    ///
    /// Left out, because C++ cannot befriend it from here, and so still unable
    /// to reach a private member in the C++ (ClangDiagAdapter makes the clang
    /// error a loud internal one): a function whose signature names a nested
    /// type, not declarable ahead of the record. A function in another
    /// namespace of the file (a `module` block's), or an `ffi "c"` or `-> !`
    /// one, is befriended by its qualified name after a declaration of its own
    /// (_ff_fn_kind); a generic friend's parameters are spelled under names of
    /// their own (Speller::rename_tparams), so they never redeclare the
    /// record's.
    fn file_friends(self, d_in: unsafe *Decl, out: unsafe *FileFriends) {
        var unsafe *d = Speller::rep(d_in)
        if !self.needs_friends(d) {
            return
        }

        out->needed = true
        var unsafe *tu = Speller::tu_of(d)
        if tu == &null || tu->program == &null {
            return
        }

        var ns = self._spell.ns_segments(d)
        // Only d itself is left out: a nested d befriends its outermost
        // record too, since C++ gives an enclosing class no access to a nested
        // one's private members.
        var unsafe *mine = d
        self._ff_dc(tu, d, mine, unsafe &ns, out)
        var hl = HoistedLocals()
        hl.run(tu)
        for var i: usize = 0; i < hl.found.size(); ++i {
            var unsafe *h = Speller::rep(hl.found[i])
            if h == &null || h->is_poisoned() || h == mine {
                continue
            }

            if isa<Declarations::ClassDecl>(h)
                || isa<Declarations::StructDecl>(h)
                || isa<Declarations::UnionDecl>(h) {
                self._ff_record(h, out)
                continue
            }

            var unsafe *f = dyn_cast<Declarations::FunctionDecl>(h)
            if f != &null {
                self._ff_add_fn(f, unsafe &ns, out)
            }
        }

        // The witnesses of what the file declares d implements: on d itself,
        // and on every `extend d impl I` of the file.
        if isa<Declarations::ClassDecl>(d) {
            var *ce = &cast<Declarations::ClassDecl>(d)->implements
            for var i: usize = 0; i < ce->size(); ++i {
                if ce->get(i) != &null {
                    self._ff_iface(ce->get(i)->base, out, 0)
                }
            }
        } else if isa<Declarations::StructDecl>(d) {
            var *se = &cast<Declarations::StructDecl>(d)->implements
            for var i: usize = 0; i < se->size(); ++i {
                if se->get(i) != &null {
                    self._ff_iface(se->get(i)->base, out, 0)
                }
            }
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            var item = *items->get(i)
            if item.kind == TopLevelKind::Stmt {
                var unsafe *ds = dyn_cast<DeclStmt>(item.as_stmt())
                var unsafe *v = if (ds != &null
                                    && ds->decl != &null) => (dyn_cast<Declarations::VariableDecl>(
                                    ds->decl,
                                ))
                                else => &null
                if v == &null || !GlobalInitReach::needs_thunk(unsafe &self._spell, v) {
                    continue
                }

                var vns = self._spell.ns_segments(v)
                if self._same_ns_vec(vns, ns) {
                    out->globals.push_back(v)
                }

                continue
            }

            if item.kind != TopLevelKind::Decl {
                continue
            }

            self._ff_ifaces_in(item.as_decl(), d, out)
        }
    }

    fn _ff_dc(self,
              dc:   unsafe *DeclContext,
              d:    unsafe *Decl,
              mine: unsafe *Decl,
              ns:   unsafe *cxx::std::vector<string>,
              out:  unsafe *FileFriends) {
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *x = *dc->dc_decls.get(i)
            if x != &null {
                self._ff_decl(x, d, mine, ns, out)
            }
        }
    }

    fn _ff_decl(self,
                x:    unsafe *Decl,
                d:    unsafe *Decl,
                mine: unsafe *Decl,
                ns:   unsafe *cxx::std::vector<string>,
                out:  unsafe *FileFriends) {
        if x->is_poisoned() {
            return
        }

        if isa<Declarations::ModuleDecl>(x) {
            self._ff_dc(
                unsafe (cast<Declarations::ModuleDecl>(x) as unsafe *DeclContext),
                d,
                mine,
                ns,
                out,
            )

            return
        }

        if isa<Declarations::VisibilityGroupDecl>(x) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(x)
            for var i: usize = 0; i < g->members.size(); ++i {
                if g->members[i] != &null {
                    self._ff_decl(g->members[i], d, mine, ns, out)
                }
            }

            return
        }

        // An `ffi "c" { ... }` block is a group like a visibility one: its
        // members are top-level declarations stamped with the linkage.
        if isa<Declarations::FFIBlockDecl>(x) {
            var unsafe *g = cast<Declarations::FFIBlockDecl>(x)
            for var i: usize = 0; i < g->body.size(); ++i {
                if g->body[i] != &null {
                    self._ff_decl(g->body[i], d, mine, ns, out)
                }
            }

            return
        }

        if isa<Declarations::ExtensionDecl>(x) {
            var unsafe *e = cast<Declarations::ExtensionDecl>(x)
            if e->methods.size() == 0 || e->target == &null || e->target->canonical == &null {
                return
            }

            // d's own scopes are friend_scopes_of's, qualified and admitted.
            var unsafe *c = canon_unqual(e->target->canonical)
            if isa<RecordType>(c)
                && self._scope_key(cast<RecordType>(c)->decl) == self._scope_key(
                    d,
                ) {
                return
            }

            // Unqualified, it names (or first declares) the struct in d's
            // namespace -- the one place it can, with no prior declaration.
            var sns = self._spell.scope_ns(e)
            if !self._same_ns_vec(sns, *ns) {
                return
            }

            var nm = self._spell.ext_scope_name(e)
            for var i: usize = 0; i < out->scopes.size(); ++i {
                if self._spell.ext_scope_name(out->scopes[i]) == nm {
                    return
                }
            }

            out->scopes.push_back(e)
            return
        }

        if isa<Declarations::ClassDecl>(x)
            || isa<Declarations::StructDecl>(x)
            || isa<Declarations::UnionDecl>(x) {
            var unsafe *r = Speller::rep(x)
            if r != x
                || r == mine
                || r->is_implicit
                || Speller::is_record_spec(r)
                || DeclFacts::decl_only_forward(r) {
                return
            }

            if DeclFacts::decl_ffi_tag_target(r) != &null || !self._plannable(r) {
                return
            }

            self._ff_record(r, out)
            return
        }

        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(x)
        if f == &null {
            return
        }

        var unsafe *rf = cast<Declarations::FunctionDecl>(Speller::rep(x))
        if self._spell.is_main(unsafe (rf as unsafe *Decl)) {
            if out->main == &null && Speller::c_linkage(rf).size() == 0 {
                out->main = rf
            }

            return
        }

        self._ff_add_fn(rf, ns, out)
    }

    fn _ff_add_fn(self,
                  f:   unsafe *Declarations::FunctionDecl,
                  ns:  unsafe *cxx::std::vector<string>,
                  out: unsafe *FileFriends) {
        var k = self._ff_fn_kind(f, ns)
        if k == 0 {
            return
        }

        for var i: usize = 0; i < out->fns.size(); ++i {
            if out->fns[i] == f {
                return
            }
        }

        out->fns.push_back(f)
        out->far.push_back((k == 2) as u8)
    }

    fn _ff_record(self, r: unsafe *Decl, out: unsafe *FileFriends) {
        for var i: usize = 0; i < out->records.size(); ++i {
            if out->records[i] == r {
                return
            }
        }

        out->records.push_back(r)
    }

    /// How \p f is befriended: 0 not at all; 1 unqualified, which names (or
    /// first declares) it in the record's namespace; 2 qualified, after an
    /// early declaration of its own (EmitPlan::friend_early) -- a function in
    /// another namespace of the file, or one whose first declaration must
    /// carry its `ffi "c"` linkage or `[[noreturn]]`, which a friend
    /// declaration may not.
    fn _ff_fn_kind(self,
                   f:  unsafe *Declarations::FunctionDecl,
                   ns: unsafe *cxx::std::vector<string>) -> u8 {
        // A specialization is befriended with its primary: a friend
        // template declaration names every specialization of it.
        if f->is_poisoned()
            || f->is_method()
            || DeclFacts::decl_extension_of(unsafe (f as unsafe *Decl)) != &null
            || Speller::is_fn_spec(unsafe (f as unsafe *Decl)) {
            return 0
        }

        if self._ff_nested(f->return_type, 0) || self._ff_nested(f->panic_result, 0) {
            return 0
        }

        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null || p->is_self {
                continue
            }

            var unsafe *pt = (if (p->is_pack && p->pack_type != &null) => (p->pack_type)
                              else => p->type_)
            if self._ff_nested(pt, 0) {
                return 0
            }
        }

        if f->is_noreturn || Speller::c_linkage(f).size() > 0 {
            return 2
        }

        var fns = self._spell.ns_segments(unsafe (f as unsafe *Decl))
        if !self._same_ns_vec(fns, *ns) {
            return 2
        }

        return 1
    }

    /// \p t names a record nested in another type: a name only a complete
    /// outer type declares, which the befriending record's definition may
    /// precede.
    fn _ff_nested(self, t: unsafe *Type, depth: u32) -> bool {
        if t == &null || depth > 32 {
            return false
        }

        var unsafe *c = if (t->canonical != &null) => (t->canonical) else => t
        match c->kind {
            case TypeKind::QualifiedType {
                return self._ff_nested(cast<QualifiedType>(c)->inner, depth + 1)
            } case TypeKind::PointerType {
                return self._ff_nested(cast<PointerType>(c)->pointee, depth + 1)
            } case TypeKind::CXXLValueRefType {
                return self._ff_nested(
                    cast<CXXLValueRefType>(c)->referee,
                    depth + 1,
                )
            } case TypeKind::CXXRValueRefType {
                return self._ff_nested(
                    cast<CXXRValueRefType>(c)->referee,
                    depth + 1,
                )
            } case TypeKind::FixedArrayType {
                return self._ff_nested(
                    cast<FixedArrayType>(c)->element,
                    depth + 1,
                )
            } case TypeKind::NullableType {
                return self._ff_nested(cast<NullableType>(c)->inner, depth + 1)
            } case TypeKind::TupleType {
                var unsafe *tt = cast<TupleType>(c)
                for var i: usize = 0; i < tt->elements.size(); ++i {
                    if self._ff_nested(*tt->elements.get(i), depth + 1) {
                        return true
                    }
                }

                return false
            } case TypeKind::FunctionPointerType {
                var unsafe *ft = cast<FunctionPointerType>(c)
                if self._ff_nested(ft->return_type, depth + 1) {
                    return true
                }

                for var i: usize = 0; i < ft->params.size(); ++i {
                    if self._ff_nested(*ft->params.get(i), depth + 1) {
                        return true
                    }
                }

                return false
            } case TypeKind::RecordType {
                var unsafe *rt = cast<RecordType>(c)
                if rt->outer != &null {
                    return true
                }

                if rt->decl != &null && !DeclFacts::decl_is_imported(rt->decl) {
                    var unsafe *dc = Speller::rep(rt->decl)->semantic_dc
                    if dc != &null
                        && dc->is_type_scope()
                        && dc->dc_kind != DeclContextKind::Extension {
                        return true
                    }
                }

                for var i: usize = 0; i < rt->args.size(); ++i {
                    if self._ff_nested(*rt->args.get(i), depth + 1) {
                        return true
                    }
                }

                return false
            } default {
                return false
            }
        }
    }

    /// Interface \p t's decl and everything it derives, once each.
    fn _ff_iface(self, t: unsafe *Type, out: unsafe *FileFriends, depth: u32) {
        if t == &null || t->canonical == &null || depth > 32 {
            return
        }

        var unsafe *c = canon_unqual(t->canonical)
        if !isa<RecordType>(c) {
            return
        }

        var unsafe *id = dyn_cast<Declarations::InterfaceDecl>(
            Speller::rep(
                DeclFacts::decl_pattern(Speller::rep(cast<RecordType>(c)->decl)),
            ),
        )

        if id == &null {
            return
        }

        var unsafe *idd = unsafe (id as unsafe *Decl)
        for var i: usize = 0; i < out->ifaces.size(); ++i {
            if out->ifaces[i] == idd {
                return
            }
        }

        out->ifaces.push_back(idd)
        for var i: usize = 0; i < id->derives_list.size(); ++i {
            var unsafe *e = id->derives_list.get(i)
            if e != &null {
                self._ff_iface(e->base, out, depth + 1)
            }
        }
    }

    fn _ff_ifaces_in(self, cand: unsafe *Decl, d: unsafe *Decl, out: unsafe *FileFriends) {
        if cand == &null {
            return
        }

        if isa<Declarations::VisibilityGroupDecl>(cand) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(cand)
            for var i: usize = 0; i < g->members.size(); ++i {
                self._ff_ifaces_in(g->members[i], d, out)
            }

            return
        }

        if isa<Declarations::FFIBlockDecl>(cand) {
            var unsafe *g = cast<Declarations::FFIBlockDecl>(cand)
            for var i: usize = 0; i < g->body.size(); ++i {
                self._ff_ifaces_in(g->body[i], d, out)
            }

            return
        }

        if isa<Declarations::ModuleDecl>(cand) {
            var unsafe *dc = unsafe (cast<Declarations::ModuleDecl>(cand) as unsafe *DeclContext)
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                self._ff_ifaces_in(*dc->dc_decls.get(i), d, out)
            }

            return
        }

        var unsafe *x = dyn_cast<Declarations::ExtensionDecl>(cand)
        if x == &null || x->implements.size() == 0 {
            return
        }

        if self._ext_target(x) != self.layout_decl(d) {
            return
        }

        for var i: usize = 0; i < x->implements.size(); ++i {
            var unsafe *e = x->implements.get(i)
            if e != &null {
                self._ff_iface(e->base, out, 0)
            }
        }
    }

    /// Where record \p d is Complete, everything its friend lines name is
    /// declared ahead of it: each record (tier 0), each function's signature
    /// types (as its own declaration would need them; the function itself
    /// need not be), each witness primary, and `main` at global scope.
    fn _admit_friends(self, d: unsafe *Decl) {
        var ff = FileFriends()
        self.file_friends(d, unsafe &ff)
        if !ff.needed {
            return
        }

        for var i: usize = 0; i < ff.records.size(); ++i {
            self._admit(ff.records[i], PlanNeed::Fwd)
        }

        for var i: usize = 0; i < ff.fns.size(); ++i {
            var unsafe *f = ff.fns[i]
            if ff.far[i] != 0 {
                var have = false
                for var k: usize = 0; k < self.friend_early.size(); ++k {
                    if self.friend_early[k] == f {
                        have = true
                        break
                    }
                }

                if !have {
                    self.friend_early.push_back(f)
                }
            }

            self._witness_bounds(f)
            for var j: usize = 0; j < f->params.size(); ++j {
                var unsafe *p = f->params[j]
                if p == &null || p->is_self {
                    continue
                }

                self._admit_type(
                    (if (p->is_pack && p->pack_type != &null) => (p->pack_type) else => p->type_),
                    PlanNeed::Fwd,
                )
            }

            self._admit_type(f->return_type, PlanNeed::Fwd)
            self._admit_type(f->panic_result, PlanNeed::Fwd)
        }

        for var i: usize = 0; i < ff.ifaces.size(); ++i {
            self._witness_primary(ff.ifaces[i])
        }

        for var i: usize = 0; i < ff.globals.size(); ++i {
            self._admit_type(ff.globals[i]->type_, PlanNeed::Fwd)
        }

        if ff.main != &null {
            self.main_friend = ff.main
            for var j: usize = 0; j < ff.main->params.size(); ++j {
                var unsafe *p = ff.main->params[j]
                if p != &null && !p->is_self {
                    self._admit_type(p->type_, PlanNeed::Fwd)
                }
            }
        }
    }
}
