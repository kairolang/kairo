/// --- The Kairo Project --------------------- Codegen/EmitPlanLayout.k --- ///
///
///   EmitPlan, part: layout queries. The record a declaration's layout is
///   read from (LayoutSpine), ADT records and anonymous unions, and whether a
///   value parameter's type reaches a template parameter by value, and the
///   records a generic value parameter's type needs complete wherever its
///   template is declared (value_param_record).
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
import AST::DeclFacts
import AST::Kind::DeclKind::DeclKind
import AST::Kind::TypeKind::TypeKind
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
import AST::Node::Types::{
    CXXLValueRefType, CXXRValueRefType, FixedArrayType, FunctionPointerType, GenericParamType,
    NullableType,     PointerType,      TupleType,
}
import Codegen::Emit::Spell::Speller
import Codegen::EmitPlan::{
    EmitPlan,
    VpNames,
}

extend EmitPlan {
    /// # Layout queries (LayoutSpine + _admit_instance)

    /// The decl whose fields define a record's layout: an instance's pattern
    /// (its shell is empty until M2 fills it), and for an ADT enum its layout
    /// record (adt_record); the representative otherwise.
    fn layout_decl(self, d: unsafe *Decl) -> unsafe *Decl {
        var unsafe *r = Speller::rep(d)
        if r != &null && DeclFacts::decl_is_instance(r) {
            // Laid out by the partial specialization the registry selected for
            // it, when one was: `Store<*i32>` has the partial's fields, not T's.
            var unsafe *e = self._cg->instances->entry_of(r)
            if e != &null && e->pattern != &null {
                r = Speller::rep(e->pattern)
            } else {
                r = Speller::rep(DeclFacts::decl_pattern(r))
            }
        }

        return self.adt_record(r)
    }

    /// The extension scope a record-targeted extension belongs to, keyed by
    /// TEMPLATE: the primary's layout decl for every form of it. One struct
    /// per name (ext_scope_name spells the primary), so `extend <> Store<bool>`
    /// and `extend <P> Store<*P>` join `extend <T> Store<T>`'s scope, each
    /// member over its own receiver, rather than three structs named alike.
    fn _scope_key(self, d: unsafe *Decl) -> unsafe *Decl {
        var unsafe *r = Speller::rep(d)
        if r == &null {
            return &null
        }

        return self.adt_record(Speller::rep(DeclFacts::decl_pattern(r)))
    }

    /// THE redirect from an ADT enum to the record it is written as
    /// (EnumDecl::adt_layout). Every walk that reads a record's members comes
    /// through here -- layout_decl, _expand_type, _needs_complete,
    /// _param_by_value_walk -- so no two of them can disagree about whether an
    /// ADT is its variants or its record. A plain enum, every other decl, and an
    /// ADT whose record was never built (sema stopped before the lowerings) are
    /// themselves.
    fn adt_record(self, d: unsafe *Decl) -> unsafe *Decl {
        var unsafe *en = dyn_cast<Declarations::EnumDecl>(d)
        if en == &null || !en->is_adt || en->adt_layout == &null {
            return d
        }

        return en->adt_layout
    }

    /// The anonymous union that field `f` (`is_anonymous_union`) declares. One
    /// resolver for every walk that sees through such a field -- the plan's,
    /// LayoutSpine's and InterfaceEmitter's -- so none of them can disagree on
    /// what the members are. A flag on a field whose type is anything else is a
    /// broken lowering, not a shape to tolerate.
    fn anon_union_of(self, f: unsafe *Declarations::FieldDecl) -> unsafe *Declarations::UnionDecl {
        var u: unsafe *Declarations::UnionDecl = &null
        if f->type_ != &null && f->type_->canonical != &null {
            var unsafe *c = canon_unqual(f->type_->canonical)
            if isa<RecordType>(c) {
                u = dyn_cast<Declarations::UnionDecl>(
                    Speller::rep(cast<RecordType>(c)->decl),
                )
            }
        }

        if u == &null || !u->is_anonymous {
            self._ice(
                f->range,
                "EmitPlan: a field marked is_anonymous_union whose type is not an anonymous union",
            )
        }

        return u
    }

    /// True iff `prim`'s layout reaches its `idx-th` generic parameter by
    /// value. `Box<T> { var v: T }` yes; `Box<T> { var p: *T }` no. Memoized.
    /// Recursion through another generic's field bottoms out at a depth cap
    /// and answers "by value", the safe direction (an over-strong edge can
    /// only trip the cycle assert, never miss a definition).
    /// param_by_value for argument `i` of an instance of `prim`, flat. An
    /// element of a pack-expanded variant's pack is held by value (a pack field
    /// is the pack itself), in the variant's `__kairo_pu` union, which the
    /// field walk does not see through: a header declaring a function that
    /// returns `Panic<T, E...>` needs every E complete (Compiler/Spec/Panic.md#the-c-view).
    fn _arg_by_value(self, prim: unsafe *Decl, i: usize) -> bool {
        var unsafe *en = dyn_cast<Declarations::EnumDecl>(prim)
        if en != &null && en->is_adt {
            var p = DeclFacts::adt_pack_param(en)
            if p != usize::MAX && i >= p {
                return true
            }
        }

        return self.param_by_value(prim, i as u32)
    }

    fn param_by_value(self, prim: unsafe *Decl, idx_in: u32) -> bool {
        if prim == &null {
            return false
        }

        // An instance's arguments past a pack's position are the pack's
        // elements (InstanceEntry::args, flat): each is held as the pack is.
        var idx = idx_in
        var pgs = DeclFacts::decl_generic_params(prim)
        for var i: usize = 0; i < pgs.size(); ++i {
            if pgs[i] != &null && pgs[i]->is_pack && (idx as usize) > i {
                idx = (i as u32)
                break
            }
        }

        // One question per record: an ADT asked as its enum or as its layout
        // record is the same one, so it gets one memo key.
        var unsafe *p  = self.layout_decl(prim)
        var        key = (p as usize as u64) << 8 ^ (idx as u64)
        for var i: usize = 0; i < self._pbv_key.size(); ++i {
            if self._pbv_key[i] == key {
                return self._pbv_val[i] != 0
            }
        }

        if self._pbv_depth > 32 {
            return true
        }

        self._pbv_depth += 1
        var ans = self._param_by_value_walk(p, idx)
        self._pbv_depth -= 1
        self._pbv_key.push_back(key)
        self._pbv_val.push_back(ans as u8)
        return ans
    }

    /// An ADT's fields are its layout record's (adt_record). `prim` stays what
    /// a generic parameter's owner is compared against (_type_reaches_param).
    fn _param_by_value_walk(self, prim: unsafe *Decl, idx: u32) -> bool {
        var unsafe *rec = self.adt_record(prim)
        match rec->kind {
            case DeclKind::ClassDecl {
                var unsafe *n = cast<Declarations::ClassDecl>(rec)
                if self._edges_reach_param(&n->derives_list, prim, idx) {
                    return true
                }

                return self._fields_reach_param(&n->fields, prim, idx)
            } case DeclKind::StructDecl {
                return self._fields_reach_param(
                    &cast<Declarations::StructDecl>(rec)->fields,
                    prim,
                    idx,
                )
            } case DeclKind::UnionDecl {
                return self._fields_reach_param(
                    &cast<Declarations::UnionDecl>(rec)->fields,
                    prim,
                    idx,
                )
            } case DeclKind::EnumDecl {
                var unsafe *n = cast<Declarations::EnumDecl>(rec)
                for var i: usize = 0; i < n->variants.size(); ++i {
                    var unsafe *v = *n->variants.get(i)
                    if v != &null && self._fields_reach_param(&v->payload, prim, idx) {
                        return true
                    }
                }

                return false
            } default {
                return false
            }
        }
    }

    fn _edges_reach_param(self,
                          list: *FrozenList<Declarations::InheritEdge>,
                          prim: unsafe *Decl,
                          idx:  u32) -> bool {
        for var i: usize = 0; i < list->size(); ++i {
            var unsafe *e = list->get(i)
            if e != &null && self._type_reaches_param(e->base, prim, idx) {
                return true
            }
        }

        return false
    }

    fn _fields_reach_param(self,
                           list: *FrozenList<unsafe *Declarations::FieldDecl>,
                           prim: unsafe *Decl,
                           idx:  u32) -> bool {
        for var i: usize = 0; i < list->size(); ++i {
            var unsafe *f = *list->get(i)
            if f == &null {
                continue
            }

            // An anonymous union's members are stored in the record by value.
            if f->is_anonymous_union {
                if self._fields_reach_param(
                    &self.anon_union_of(f)->fields,
                    prim,
                    idx,
                ) {
                    return true
                }

                continue
            }

            if self._type_reaches_param(f->type_, prim, idx) {
                return true
            }
        }

        return false
    }

    fn _type_reaches_param(self, t: unsafe *Type, prim: unsafe *Decl, idx: u32) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        match c->kind {
            case TypeKind::QualifiedType {
                return self._type_reaches_param(
                    cast<QualifiedType>(c)->inner,
                    prim,
                    idx,
                )
            } case TypeKind::NullableType {
                return self._type_reaches_param(
                    cast<NullableType>(c)->lowered,
                    prim,
                    idx,
                )
            } case TypeKind::GenericParamType {
                var unsafe *g = cast<GenericParamType>(c)
                // Both through layout_decl: walking an ADT's record, `prim` is
                // that record while T's owner is the enum.
                return self.layout_decl(g->owner) == self.layout_decl(prim) && g->param_index == idx
            } case TypeKind::RecordType {
                var unsafe *r = cast<RecordType>(c)
                var unsafe *d = self.layout_decl(r->decl)
                // A payload struct is laid out inside its ADT (LayoutSpine::reaches).
                var unsafe *ps = dyn_cast<Declarations::StructDecl>(d)
                if ps != &null && ps->is_adt_payload {
                    return self._fields_reach_param(&ps->fields, prim, idx)
                }

                for var i: usize = 0; i < r->args.size(); ++i {
                    if !self.param_by_value(d, i as u32) {
                        continue
                    }

                    if self._type_reaches_param(*r->args.get(i), prim, idx) {
                        return true
                    }
                }

                return false
            } case TypeKind::TupleType {
                var unsafe *tp = cast<TupleType>(c)
                for var i: usize = 0; i < tp->elements.size(); ++i {
                    if self._type_reaches_param(*tp->elements.get(i), prim, idx) {
                        return true
                    }
                }

                return false
            } case TypeKind::FixedArrayType {
                return self._type_reaches_param(
                    cast<FixedArrayType>(c)->element,
                    prim,
                    idx,
                )
            } default {
                return false
            }
        }
    }

    /// `who` has a generic value parameter whose type is a record (Compiler/Spec/Eval.md
    /// 7e): `dep` that record, or with `dep` null, any. C++ needs that class
    /// complete at every declaration of the template, its forward one included.
    fn value_param_record(self, who: unsafe *Decl, dep: unsafe *Decl) -> bool {
        if who == &null {
            return false
        }

        var gps = DeclFacts::decl_generic_params(who)
        for var i: usize = 0; i < gps.size(); ++i {
            var unsafe *gp = gps[i]
            if gp == &null
                || !gp->is_const_param
                || gp->value_type == &null
                || gp->value_type->canonical == &null {
                continue
            }

            var unsafe *c = canon_unqual(gp->value_type->canonical)
            if !isa<RecordType>(c) {
                continue
            }

            if dep == &null {
                return true
            }

            if Speller::rep(cast<RecordType>(c)->decl) == dep {
                return true
            }
        }

        return false
    }

    /// `who`'s VpNames, walked once and memoized: each class `dep` for
    /// which `who`'s definition names a template over a value parameter of
    /// class `dep` (value_param_record), in any position -- bases, fields,
    /// method returns and non-self parameters, through pointers and
    /// arguments to a fixed depth -- (vp), and each record it names as the
    /// owner of a nested type (nest). Such a template is declared only once
    /// `dep` is complete (InterfaceEmitter::_vp_fwd_decls), so `who`'s
    /// definition follows `dep`'s even where its layout does not.
    fn _vp_row(self, who: unsafe *Decl) -> usize {
        var key = (who as usize as u64)
        var hit = self._vp_memo.find(key)
        if hit != self._vp_memo.end() {
            return hit->second as usize
        }

        var row = VpNames()
        var unsafe *rec = self.adt_record(who)
        var fields:  unsafe *FrozenList<unsafe *Declarations::FieldDecl>    = &null
        var methods: unsafe *FrozenList<unsafe *Declarations::FunctionDecl> = &null
        match rec->kind {
            case DeclKind::ClassDecl {
                var unsafe *n = cast<Declarations::ClassDecl>(rec)
                for var i: usize = 0; i < n->derives_list.size(); ++i {
                    var unsafe *e = n->derives_list.get(i)
                    if e != &null {
                        self._vp_collect(e->base, 0, &row)
                    }
                }

                fields  = unsafe &n->fields
                methods = unsafe &n->methods
            } case DeclKind::StructDecl {
                fields  = unsafe &cast<Declarations::StructDecl>(rec)->fields
                methods = unsafe &cast<Declarations::StructDecl>(rec)->methods
            } case DeclKind::UnionDecl {
                fields  = unsafe &cast<Declarations::UnionDecl>(rec)->fields
                methods = unsafe &cast<Declarations::UnionDecl>(rec)->methods
            } default { }
        }

        if fields != &null {
            for var i: usize = 0; i < fields->size(); ++i {
                var unsafe *f = *fields->get(i)
                if f != &null {
                    self._vp_collect(f->type_, 0, &row)
                }
            }

            for var i: usize = 0; i < methods->size(); ++i {
                var unsafe *m = *methods->get(i)
                if m == &null {
                    continue
                }

                self._vp_collect(m->return_type, 0, &row)
                for var j: usize = 0; j < m->params.size(); ++j {
                    var unsafe *p = *m->params.get(j)
                    if p != &null && !p->is_self {
                        self._vp_collect(p->type_, 0, &row)
                    }
                }
            }
        }

        var at = self._vp_rows.size()
        self._vp_rows.push_back(row)
        self._vp_memo.try_emplace(key, at as u64)
        return at
    }

    fn _vp_collect(self, t: unsafe *Type, depth: u32, row: *VpNames) {
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
                self._vp_collect(cast<QualifiedType>(c)->inner, d1, row)
            } case TypeKind::PointerType {
                self._vp_collect(cast<PointerType>(c)->pointee, d1, row)
            } case TypeKind::CXXLValueRefType {
                self._vp_collect(cast<CXXLValueRefType>(c)->referee, d1, row)
            } case TypeKind::CXXRValueRefType {
                self._vp_collect(cast<CXXRValueRefType>(c)->referee, d1, row)
            } case TypeKind::NullableType {
                self._vp_collect(cast<NullableType>(c)->lowered, d1, row)
            } case TypeKind::FixedArrayType {
                self._vp_collect(cast<FixedArrayType>(c)->element, d1, row)
            } case TypeKind::TupleType {
                var unsafe *tp = cast<TupleType>(c)
                for var i: usize = 0; i < tp->elements.size(); ++i {
                    self._vp_collect(*tp->elements.get(i), d1, row)
                }
            } case TypeKind::FunctionPointerType {
                var unsafe *fp = cast<FunctionPointerType>(c)
                for var i: usize = 0; i < fp->params.size(); ++i {
                    self._vp_collect(*fp->params.get(i), d1, row)
                }

                self._vp_collect(fp->return_type, d1, row)
            } case TypeKind::RecordType {
                var unsafe *r = cast<RecordType>(c)
                var unsafe *d = Speller::rep(r->decl)
                if d != &null {
                    // value_param_record(rep(pattern), dep) for any dep: the
                    // record-typed value parameters of the named template.
                    var unsafe *pat = Speller::rep(DeclFacts::decl_pattern(d))
                    if pat != &null {
                        var gps = DeclFacts::decl_generic_params(pat)
                        for var i: usize = 0; i < gps.size(); ++i {
                            var unsafe *gp = gps[i]
                            if gp == &null
                                || !gp->is_const_param
                                || gp->value_type == &null
                                || gp->value_type->canonical == &null {
                                continue
                            }

                            var unsafe *vc = canon_unqual(
                                gp->value_type->canonical,
                            )

                            if !isa<RecordType>(vc) {
                                continue
                            }

                            row->vp.insert(
                                Speller::rep(cast<RecordType>(vc)->decl) as usize as u64,
                            )
                        }
                    }

                    // A nested type's outermost owner (d != dep there, so only
                    // an owner that is not d itself).
                    var unsafe *o = self._outermost_type(d)
                    if o != d {
                        row->nest.insert(o as usize as u64)
                    }
                }

                for var i: usize = 0; i < r->args.size(); ++i {
                    self._vp_collect(*r->args.get(i), d1, row)
                }
            } default { }
        }
    }
}
