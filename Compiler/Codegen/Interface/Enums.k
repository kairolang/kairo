/// --- The Kairo Project -------------------- Codegen/Interface/Enums.k --- ///
///
///   InterfaceEmitter, part: enums. Plain enums, and an ADT enum written as
///   the record EnumLayoutLowering built (EnumDecl::adt_layout): its tag and
///   payload storage, the niche record a nullable-shaped enum packs into, and
///   its role functions, rendered from FunctionDecl::adt_role / adt_form.
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

import AST::Context::DeclContext::DeclContext
import AST::DeclFacts
import AST::EnumNiche::{
    adt_first_spare_tag,
    adt_niche_dataless,
    adt_niche_pattern_of,
    adt_niche_payload_variant,
    adt_tag_niche_count,
    enum_niche_count,
}
import AST::LangItems::LowerTargets
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
    RecordType,
    builtin_info,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Types::PointerType
import Codegen::Interface::Derived
import Codegen::Interface::Fields
import Codegen::Interface::InterfaceEmitter::InterfaceEmitter
import Codegen::Interface::Interop
import Codegen::Interface::Records
import Codegen::Plan::EmitPlan
import Codegen::Spell::Spell::{
    Speller,
    VIS_PUB,
}

extend InterfaceEmitter {
    /// `max(floor, alignof(P)...)` over `lay`'s payload structs, the pack
    /// variant's expanded: the initializer of `__kairo_payload_offset`.
    priv fn _payload_offset_init(self,
                                 en:  unsafe *Declarations::EnumDecl,
                                 lay: unsafe *Declarations::StructDecl) -> string {
        var        ps  = ""
        var unsafe *dc = unsafe (lay as unsafe *DeclContext)
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *sd = dyn_cast<Declarations::StructDecl>(
                *dc->dc_decls.get(i),
            )

            if sd == &null || !sd->is_adt_payload {
                continue
            }

            if ps.size() > 0 {
                ps += ", "
            }

            if sd->adt_pack_param != &null {
                ps += self._pack_payload(sd, lay->adt_of) + "..."
            } else {
                ps += self._spell->leaf(sd)
            }
        }

        return "::" + LowerTargets::max_align() + "<" + ps + ">(" + f"{en->adt_union_align}" + ")"
    }

    /// The tag element `k` (a C++ expression: a template parameter) of
    /// `en`'s pack-expanded variant `v` is stored as, typed as the tag
    /// enum `tt`: the variant's position plus k, or under type-id tags
    /// the element's id. EnumLayoutQuery::tag_value is the same rule.
    priv fn _pack_tag(self,
                      en:       unsafe *Declarations::EnumDecl,
                      v:        unsafe *Declarations::EnumVariantDecl,
                      const k:  string,
                      const tt: string) -> string {
        if en->adt_explicit_tags {
            return "static_cast<" + tt + ">(::" + LowerTargets::type_id() + "<" + LowerTargets::clang_pack_element() + "<" + k + ", " + self._pack_name(
                en,
            ) + "...>>)"
        }

        return "static_cast<" + tt + ">(" + f"{v->adt_tag_value}" + " + " + k + ")"
    }

    /// The enum's type pack parameter, as its own body names it.
    priv fn _pack_name(self, en: unsafe *Declarations::EnumDecl) -> string {
        var unsafe *gp = en->generic_params[DeclFacts::adt_pack_param(en)]
        return self._spell->tok_name(
            gp->name,
            Speller::fid_of(unsafe (en as unsafe *Decl)),
        )
    }

    /// The payload struct template of pack-expanded variant `v`, applied
    /// to its pack, unexpanded: `__kairo_Err_t<E>`, the pattern a fold or
    /// a `__kairo_pu<...>` expands.
    prot fn _pack_payload(self, ps: unsafe *Declarations::StructDecl, en: unsafe *Decl) -> string {
        var unsafe *gp = ps->adt_pack_param
        return self._spell->leaf(unsafe (ps as unsafe *Decl)) + "<" + self._spell->tok_name(
            gp->name,
            Speller::fid_of(en),
        ) + ">"
    }

    /// The payload struct an ADT union member `m` holds, or null.
    prot fn _member_payload(self,
                            m: unsafe *Declarations::FieldDecl) -> unsafe *Declarations::StructDecl {
        if m == &null || m->type_ == &null || m->type_->canonical == &null {
            return &null
        }

        var unsafe *c = canon_unqual(m->type_->canonical)
        if !isa<RecordType>(c) {
            return &null
        }

        return dyn_cast<Declarations::StructDecl>(cast<RecordType>(c)->decl)
    }

    prot fn _enum_def(self, en: unsafe *Declarations::EnumDecl) {
        // An ADT is written as the record EnumLayoutLowering built for it; a
        // plain enum, an ADT's tag enum included, as an `enum class`.
        var unsafe *rec = self._plan->adt_record(en)
        if rec != en {
            self._adt_def(en, cast<Declarations::StructDecl>(rec))
            return
        }

        if en->is_adt {
            self._ice(
                self._at(en),
                "InterfaceEmitter: ADT enum reached codegen without its layout record; sema stopped before EnumLayoutLowering",
            )
        }

        var at = self._at(en)
        var s  = "enum class "
        s += self._spell->leaf(unsafe (en as unsafe *Decl))
        s += " : "
        s += self._enum_underlying(en)
        s += " {"
        self._cg->sink->spell(at, s)
        // With no discriminant anywhere every value is its position, which
        // is C++'s own numbering, so the names go out bare. That is also the
        // only form an enum the compiler mints can take: it is built after
        // X, so its value slots were never written.
        var numbered = false
        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v != &null && v->discriminant != &null {
                numbered = true
                break
            }

            // A minted tag enum has no discriminant expression; an explicit
            // tag (EnumLayoutLowering's knobs) is a value that is not its
            // position.
            if v != &null && v->value.ok && (v->value.neg || v->value.mag != (i as u64)) {
                numbered = true
                break
            }
        }

        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v == &null {
                continue
            }

            var vs = self._spell->leaf(v)
            if numbered {
                // Every variant, written discriminant or not, gets the value
                // X computed: the source text of a discriminant may name
                // other variants or constants C++ cannot see by those names.
                // Not ok only after an error X reported; --print-cxx still
                // renders such a TU, and a bare name is the harmless form.
                if v->value.ok {
                    vs += " = " + self._enum_value(v->value)
                }
            }

            vs += ","
            self._cg->sink->spell(v->name.range, vs)
        }

        self._cg->sink->spell(at, "};")
        self._cg->sink->brk()
    }

    /// An ADT enum: the record EnumLayoutLowering built for it, written
    /// under the enum's own name and template head in place of an `enum
    /// class`, in the record's order -- the tag enum and the payload
    /// structs, the tag, the anonymous union, the flags, the role functions
    /// -- then the friends. Every type inside is spelled with the ENUM as
    /// its scope: the record's members belong to it (their semantic_dc), so
    /// its nested types go out by leaf, as a record's own do in _record_def.
    priv fn _adt_def(self,
                     en:  unsafe *Declarations::EnumDecl,
                     lay: unsafe *Declarations::StructDecl) {
        var unsafe *d      = unsafe (en as unsafe *Decl)
        var        at      = self._at(d)
        var        nm      = self._spell->leaf(d)
        var        generic = Speller::template_params(d).size() > 0
        if en->adt_niche {
            self._niche_record(en, lay, "struct " + nm + " {", false)
            return
        }

        self._cg->sink->spell(
            at,
            self._spell->template_head(d) + "struct " + nm + " {",
        )

        self._body_predicate_asserts(d)

        // A struct: public unless marked. Only the two helpers the special
        // members call are private. The tag must stay public: `==` on an ADT
        // is a compare of two values' tags, written by OperatorLowering in
        // the user's code, outside the record.
        var        cur_access = VIS_PUB()
        var unsafe *dc        = unsafe (lay as unsafe *DeclContext)
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *nd = *dc->dc_decls.get(i)
            if nd == &null || !self._is_type(nd) {
                continue
            }

            // Written where its field is (_anon_union_field).
            if isa<Declarations::UnionDecl>(nd) && cast<Declarations::UnionDecl>(nd)->is_anonymous {
                continue
            }

            cur_access = self._access(cur_access, self._cxx_vis(nd), false, at)
            // A pack-expanded variant's payload: a template over one element,
            // inside which the enum's pack spells as that element.
            var unsafe *pps = dyn_cast<Declarations::StructDecl>(nd)
            var unsafe *pk  = if (pps != &null) => (pps->adt_pack_param) else => &null
            if pk != &null {
                self._cg->sink->spell(
                    self._at(nd),
                    "template <class " + LowerTargets::adt_pack_elem() + ">",
                )

                self._spell->pack_alias = pk
            }

            // `Panic<void, ...>`'s Ok: T is spelled `__kairo_nv<T>` there.
            var vu = pps != &null && pps->is_adt_payload && en->adt_void_unit
            if vu {
                self._spell->void_unit_owner = d
            }

            self._type_def(Speller::rep(nd))
            if vu {
                self._spell->void_unit_owner = &null
            }

            if pk != &null {
                self._spell->pack_alias = &null
            }
        }

        for var i: usize = 0; i < lay->fields.size(); ++i {
            var unsafe *f = lay->fields[i]
            if f == &null {
                continue
            }

            cur_access = self._access(cur_access, self._cxx_vis(f), false, at)
            if f->is_anonymous_union {
                self._anon_union_field(f, d)
                continue
            }

            // A tag in the payloads' common prefix is read through the
            // union's tag-only member, not stored beside it.
            if en->adt_tag_member != &null && f == en->adt_tag_field {
                continue
            }

            var fnm = self._spell->leaf(unsafe (f as unsafe *Decl))
            // A flag: a compile-time constant with no Kairo expression behind
            // it (_adt_flag).
            if f->storage == Declarations::StorageClass::Eval {
                if f == en->adt_payload_offset {
                    var u = builtin_info(BuiltinKind::U32)->cxx.copy()
                    self._cg->sink->spell(
                        f->name.range,
                        "static constexpr " + u + " " + fnm + " = " + self._payload_offset_init(
                            en,
                            lay,
                        ) + ";",
                    )

                    continue
                }

                self._cg->sink->spell(
                    f->name.range,
                    "static constexpr bool " + fnm + " = " + self._adt_flag(
                        lay,
                        f,
                        fnm,
                    ) + ";",
                )

                continue
            }

            self._cg->sink->spell(
                f->name.range,
                self._spell->decl(f->type_, fnm, &null, d) + ";",
            )
        }

        for var i: usize = 0; i < lay->methods.size(); ++i {
            var unsafe *m = lay->methods[i]
            if m == &null {
                continue
            }

            // Prefix-tagged: every special member is the defaulted one, so
            // the helpers that switch on the tag are never called.
            if en->adt_tag_member != &null
                && (m->adt_role == Declarations::AdtRole::Destroy
                    || m->adt_role == Declarations::AdtRole::ConstructFrom) {
                continue
            }

            cur_access = self._access(cur_access, self._cxx_vis(m), false, at)
            self._cg->sink->spell(
                self._at(unsafe (m as unsafe *Decl)),
                self._adt_member(en, m, nm, generic),
            )
        }

        // The niche the tag leaves (EnumNiche: the tag values past the
        // variants), for `__kairo_niche<E>`: a niche-filled ADT holding
        // this one stores its dataless variants as those tags.
        cur_access = self._access(cur_access, VIS_PUB(), false, at)
        self._adt_factories(en, lay, nm, generic)
        self._cxx_alloc_ops(d, nm, at)
        var tt = LowerTargets::adt_tag_type()
        var nv = f"{adt_first_spare_tag(en)}"
        var w  = builtin_info(BuiltinKind::U64)->cxx.copy()
        // The tag as written and as read: a member of its own, or the
        // union's tag-only member in the common prefix.
        var tset = LowerTargets::adt_tag_field() + "(static_cast<" + tt + ">(" + nv + " + i))"
        var tget = LowerTargets::adt_tag_field()
        if en->adt_tag_member != &null {
            var tmn = self._spell->leaf(en->adt_tag_member)
            tset = tmn.copy() + "{static_cast<" + tt + ">(" + nv + " + i)}"
            tget = tmn + "." + LowerTargets::adt_tag_field()
        }

        self._cg->sink->spell(
            at,
            "static constexpr " + w + " " + LowerTargets::niche_count() + " = " + f"{adt_tag_niche_count(en)}" + ";",
        )

        self._cg->sink->spell(
            at,
            nm.copy() + "(::" + LowerTargets::niche_ctor_tag() + ", " + w + " i) noexcept : " + tset + " {}",
        )

        self._cg->sink->spell(
            at,
            "static bool " + LowerTargets::niche_test() + "(const " + nm + "& v, " + w + " i) noexcept { return static_cast<" + w + ">(v." + tget + ") == " + nv + " + i; }",
        )

        self._friends(d)

        self._cg->sink->spell(at, "};")
        self._cg->sink->brk()

        // The niche-filled form of a generic ADT, as a partial specialization
        // constrained on exactly what EnumLayoutQuery::niche_verdict asks:
        // C++ picks it per instance, in every TU and every C++ host alike,
        // so no instance Sema never saw (a generic body's) can disagree.
        if generic && en->adt_niche_shape {
            var gps  = Speller::template_params(d)
            var args = ""
            for var i: usize = 0; i < gps.size(); ++i {
                if i > 0 {
                    args += ", "
                }

                args += self._spell->tok_name(gps[i]->name, Speller::fid_of(d))
                if gps[i]->is_pack {
                    args += "..."
                }
            }

            var ft = self._niche_field_spelling(en)
            var cond = "::" + LowerTargets::niche_trait() + "<" + ft + ">::" + LowerTargets::niche_trait_count() + " >= " + f"{adt_niche_dataless(en)}" + " && __is_trivially_copyable(" + ft + ") && __is_trivially_destructible(" + ft + ")"
            self._niche_record(
                en,
                lay,
                self._spell->template_head(
                    d,
                ) + "requires (" + cond + ") struct " + nm + "<" + args + "> {",
                true,
            )
        }
    }

    /// The C++ type of a niche-shaped ADT's one payload field, spelled in the
    /// enum's own scope (a generic one's in terms of its parameters).
    priv fn _niche_field_spelling(self, en: unsafe *Declarations::EnumDecl) -> string {
        var unsafe *pv = en->variants[adt_niche_payload_variant(en) as usize]
        return self._spell->decl(pv->payload[0]->type_, "", &null, en)
    }

    /// A niche-filled ADT record (EnumLayoutLowering's header): no tag and
    /// no union, the payload struct as the one member, each dataless
    /// variant a pattern of its field from `__kairo_niche<F>`. Written for a
    /// non-generic ADT whose verdict was niche, and as the partial
    /// specialization beside every niche-shaped generic one (`spec`). The
    /// special members are the defaulted ones (the field is trivially
    /// copied and destroyed, which is the rule's condition), so the
    /// destroy and construct helpers, which switch on a tag, are not
    /// written. The record still declares `__kairo_Tag` for
    /// `__kairo_which()`, and answers the niche trait itself: a niche-filled
    /// ADT holding this one uses the field's patterns past these.
    priv fn _niche_record(self,
                          en:         unsafe *Declarations::EnumDecl,
                          lay:        unsafe *Declarations::StructDecl,
                          const head: string,
                          spec:       bool) {
        var unsafe *d   = unsafe (en as unsafe *Decl)
        var        at   = self._at(d)
        var        nm   = self._spell->leaf(d)
        var        p    = adt_niche_payload_variant(en)
        var unsafe *pv  = en->variants[p as usize]
        var unsafe *fld = pv->payload[0]
        var        ft   = self._niche_field_spelling(en)
        var        mem  = self._spell->leaf(pv->adt_member)
        var        fnm  = self._spell->leaf(unsafe (fld as unsafe *Decl))
        var        nt   = "::" + LowerTargets::niche_trait() + "<" + ft + ">::"
        var        w    = builtin_info(BuiltinKind::U64)->cxx.copy()
        var        dl   = adt_niche_dataless(en)
        var        tt   = LowerTargets::adt_tag_type()
        self._cg->sink->spell(at, head)

        var unsafe *dc = unsafe (lay as unsafe *DeclContext)
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *nd = *dc->dc_decls.get(i)
            if nd == &null || !self._is_type(nd) {
                continue
            }

            if isa<Declarations::UnionDecl>(nd) && cast<Declarations::UnionDecl>(nd)->is_anonymous {
                continue
            }

            self._type_def(Speller::rep(nd))
        }

        self._cg->sink->spell(
            at,
            self._spell->leaf(self._payload_struct_of(pv)) + " " + mem + ";",
        )

        // A generic ADT's flags, which the Null surface's constraints
        // read: true by the specialization's own constraint.
        for var i: usize = 0; i < lay->fields.size(); ++i {
            var unsafe *f = lay->fields[i]
            if f == &null || f->storage != Declarations::StorageClass::Eval {
                continue
            }

            self._cg->sink->spell(
                f->name.range,
                "static constexpr bool " + self._spell->leaf(
                    unsafe (f as unsafe *Decl),
                ) + " = true;",
            )
        }

        var nx = self._adt_noexcept()
        for var i: usize = 0; i < lay->methods.size(); ++i {
            var unsafe *m = lay->methods[i]
            if m == &null {
                continue
            }

            var mat = self._at(unsafe (m as unsafe *Decl))
            if Declarations::adt_role_is_nullable(m->adt_role) {
                self._cg->sink->spell(
                    mat,
                    self._niche_nullable_member(en, m, nm, nt, mem, fnm, ft),
                )

                continue
            }

            match m->adt_role {
                case Declarations::AdtRole::VariantCtor {
                    var vt = "::" + LowerTargets::adt_variant_tag() + f"<{m->adt_variant}>"
                    if m->adt_variant == p {
                        // The field constructor every concrete site calls,
                        // and the lambda one a generic body's site calls.
                        self._cg->sink->spell(
                            mat,
                            "constexpr " + nm + "(" + vt + ", " + self._spell->decl(
                                fld->type_,
                                fnm,
                                &null,
                                d,
                            ) + ")" + nx + " : " + mem + "{" + fnm + "} {}",
                        )

                        self._cg->sink->spell(
                            mat,
                            "template <class F> constexpr " + nm + "(" + vt + ", F&& f)" + nx + " : " + mem + "(static_cast<F&&>(f)()) {}",
                        )
                    } else {
                        self._cg->sink->spell(
                            mat,
                            "constexpr " + nm + "(" + vt + ")" + nx + " : " + mem + "{" + nt + LowerTargets::niche_trait_pattern() + "(" + f"{adt_niche_pattern_of(en, m->adt_variant)}" + ")} {}",
                        )
                    }
                } case Declarations::AdtRole::CopyCtor {
                    if m->adt_form == Declarations::AdtForm::Trivial {
                        self._cg->sink->spell(
                            mat,
                            nm.copy() + "(const " + nm + "&) = default;",
                        )
                    }
                } case Declarations::AdtRole::MoveCtor {
                    if m->adt_form == Declarations::AdtForm::Trivial {
                        self._cg->sink->spell(
                            mat,
                            nm.copy() + "(" + nm + "&&) = default;",
                        )
                    }
                } case Declarations::AdtRole::CopyAssign {
                    if m->adt_form == Declarations::AdtForm::Trivial {
                        self._cg->sink->spell(
                            mat,
                            nm.copy() + "& operator=(const " + nm + "&) = default;",
                        )
                    }
                } case Declarations::AdtRole::MoveAssign {
                    if m->adt_form == Declarations::AdtForm::Trivial {
                        self._cg->sink->spell(
                            mat,
                            nm.copy() + "& operator=(" + nm + "&&) = default;",
                        )
                    }
                } case Declarations::AdtRole::Dtor {
                    if m->adt_form == Declarations::AdtForm::Trivial {
                        self._cg->sink->spell(mat, "~" + nm + "() = default;")
                    }
                } case Declarations::AdtRole::Which {
                    var s = "constexpr " + tt + " " + LowerTargets::adt_which() + "() const" + nx + " { return "
                    for var k: usize = 0; k < en->variants.size(); ++k {
                        if (k as u32) == p {
                            continue
                        }

                        s += nt.copy() + LowerTargets::niche_trait_test() + "(" + mem + "." + fnm + ", " + f"{adt_niche_pattern_of(en, (k as u32))}" + ") ? " + tt + "::" + self._tag_leaf(
                            en,
                            en->variants[k],
                        ) + " : "
                    }

                    self._cg->sink->spell(
                        mat,
                        s + tt + "::" + self._tag_leaf(en, pv) + "; }",
                    )
                } default { // destroy and construct_from: no tag to switch on.
                    0
                }
            }
        }

        // A struct: public throughout. The generic primary's partial
        // specialization gets them too, or C++ would find them only on the
        // instances it lays out tagged.
        self._adt_factories(
            en,
            lay,
            nm,
            spec || Speller::template_params(d).size() > 0,
        )

        self._cxx_alloc_ops(d, nm, at)
        self._cg->sink->spell(
            at,
            "static constexpr " + w + " " + LowerTargets::niche_count() + " = " + nt + LowerTargets::niche_trait_count() + " - " + f"{dl}" + ";",
        )

        self._cg->sink->spell(
            at,
            "constexpr " + nm + "(::" + LowerTargets::niche_ctor_tag() + ", " + w + " i) noexcept : " + mem + "{" + nt + LowerTargets::niche_trait_pattern() + "(" + f"{dl}" + " + i)} {}",
        )

        self._cg->sink->spell(
            at,
            "static constexpr bool " + LowerTargets::niche_test() + "(const " + nm + "& v, " + w + " i) noexcept { return " + nt + LowerTargets::niche_trait_test() + "(v." + mem + "." + fnm + ", " + f"{dl}" + " + i); }",
        )

        self._friends(d)
        self._cg->sink->spell(at, "};")
        self._cg->sink->brk()
        if !spec {
            // Pinned: no tag means the record is its payload struct.
            var ps = self._spell->leaf(self._payload_struct_of(pv))
            self._cg->sink->spell(
                at,
                "static_assert(sizeof(" + nm + ") == sizeof(" + nm + "::" + ps + ") && __is_standard_layout(" + nm + "));",
            )

            self._cg->sink->brk()
        }
    }

    /// The payload struct variant `v`'s union member is typed as.
    prot fn _payload_struct_of(self, v: unsafe *Declarations::EnumVariantDecl) -> unsafe *Decl {
        var unsafe *t              = v->adt_member->type_
        var        c: unsafe *Type = &null
        if t != &null && t->canonical != &null {
            c = canon_unqual(t->canonical)
        }

        if c == &null || !isa<RecordType>(c) {
            self._ice(
                self._at(unsafe (v as unsafe *Decl)),
                "InterfaceEmitter: an ADT union member whose type is not its payload struct; EnumLayoutLowering gate failure",
            )
        }

        return cast<RecordType>(c)->decl
    }

    /// The Null lang item's surface over the niche-filled record: null is
    /// pattern 0 in the field, present is any other value, `==` is the
    /// field's own (two nulls hold the same pattern).
    priv fn _niche_nullable_member(self,
                                   en:        unsafe *Declarations::EnumDecl,
                                   m:         unsafe *Declarations::FunctionDecl,
                                   const nm:  string,
                                   const nt:  string,
                                   const mem: string,
                                   const fnm: string,
                                   const ft:  string) -> string {
        var        at  = self._at(unsafe (m as unsafe *Decl))
        var unsafe *d  = unsafe (en as unsafe *Decl)
        var        nx  = self._adt_noexcept()
        var        val = LowerTargets::nullable_value()
        var nul = mem.copy() + "{" + nt + LowerTargets::niche_trait_pattern() + "(0)} {}"
        match m->adt_role {
            case Declarations::AdtRole::NullDefault {
                return "constexpr " + nm + "()" + nx + " : " + nul
            } case Declarations::AdtRole::NullFrom {
                if m->params.size() != 1 {
                    self._ice(
                        at,
                        "InterfaceEmitter: Null(null_t) without its parameter",
                    )

                    return ""
                }

                return "constexpr " + nm + "(" + self._spell->decl(
                    m->params[0]->type_,
                    "",
                    &null,
                    d,
                ) + ")" + nx + " : " + nul
            } case Declarations::AdtRole::ValueCopy {
                return "constexpr " + nm + "(const " + ft + "& v)" + nx + " : " + mem + "{v} {}"
            } case Declarations::AdtRole::ValueMove {
                return "constexpr " + nm + "(" + ft + "&& v)" + nx + " : " + mem + "{static_cast<" + ft + "&&>(v)} {}"
            } case Declarations::AdtRole::IsNull {
                return "constexpr bool " + LowerTargets::nullable_is_null() + "() const" + nx + " { return " + nt + LowerTargets::niche_trait_test() + "(" + mem + "." + fnm + ", 0); }"
            } case Declarations::AdtRole::ValueRef {
                return "constexpr " + ft + "& " + val + "()" + nx + " { return " + mem + "." + fnm + "; }"
            } case Declarations::AdtRole::ValueCref {
                return "constexpr const " + ft + "& " + val + "() const" + nx + " { return " + mem + "." + fnm + "; }"
            } case Declarations::AdtRole::Equal {
                return "constexpr bool operator==(const " + nm + "& o) const" + nx + " requires requires (const " + ft + "& a) { a == a; } { return " + mem + "." + fnm + " == o." + mem + "." + fnm + "; }"
            } default {
                0
            }
        }

        self._ice(at, "InterfaceEmitter: a Null role with no niche rendering")

        return ""
    }

    /// `__kairo_niche<E>` for plain enum `en` (EnumNiche): the values past
    /// its variants. At global scope, where the trait is, so the enum is
    /// spelled qualified.
    prot fn _enum_niche_trait(self, en: unsafe *Declarations::EnumDecl) {
        var at = self._at(en)
        var e  = self._spell->qual_name(en)
        var w  = builtin_info(BuiltinKind::U64)->cxx.copy()
        var nv = f"{en->variants.size()}"
        self._cg->sink->spell(
            at,
            "template <> struct " + LowerTargets::niche_trait() + "<" + e + "> { static constexpr " + w + " " + LowerTargets::niche_trait_count() + " = " + f"{enum_niche_count(en)}" + "; static constexpr " + e + " " + LowerTargets::niche_trait_pattern() + "(" + w + " i) noexcept { return static_cast<" + e + ">(" + nv + " + i); } static constexpr bool " + LowerTargets::niche_trait_test() + "(const " + e + "& v, " + w + " i) noexcept { return v == static_cast<" + e + ">(" + nv + " + i); } };",
        )

        self._cg->sink->brk()
    }

    /// A flag's initializer: its type trait over every payload struct,
    /// joined with `&&`. Which flag it is is read off the name LowerTargets
    /// gave it; the structs go by leaf, the text being inside the record.
    priv fn _adt_flag(self,
                      lay:      unsafe *Declarations::StructDecl,
                      f:        unsafe *Declarations::FieldDecl,
                      const nm: string) -> string {
        var        s   = ""
        var unsafe *dc = unsafe (lay as unsafe *DeclContext)
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *ps = dyn_cast<Declarations::StructDecl>(
                *dc->dc_decls.get(i),
            )

            if ps == &null || !ps->is_adt_payload {
                continue
            }

            var p = self._spell->leaf(ps)
            // A pack-expanded variant's: every element's, as a fold (true
            // for an empty pack).
            var fold = ps->adt_pack_param != &null
            if fold {
                p = self._pack_payload(ps, lay->adt_of)
            }

            var term = ""
            if nm == LowerTargets::adt_trivial_dtor() {
                term = "__is_trivially_destructible(" + p + ")"
            } else if nm == LowerTargets::adt_trivial_copy() {
                term = "__is_trivially_copyable(" + p + ")"
            } else if nm == LowerTargets::adt_destructible() {
                term = "__is_destructible(" + p + ")"
            } else if nm == LowerTargets::adt_copyable() {
                term = "__is_constructible(" + p + ", const " + p + "&)"
            } else if nm == LowerTargets::adt_movable() {
                term = "__is_constructible(" + p + ", " + p + "&&)"
            } else {
                self._ice(
                    self._at(unsafe (f as unsafe *Decl)),
                    f"InterfaceEmitter: ADT record field '{nm}' is compile-time but none of the five flags",
                )
            }

            if fold {
                term = "(" + term + " && ...)"
            }

            if s.size() > 0 {
                s += " && "
            }

            s += term
        }

        if s.size() == 0 {
            self._ice(
                self._at(unsafe (f as unsafe *Decl)),
                "InterfaceEmitter: an ADT record with flags and no payload struct; EnumLayoutLowering gate failure",
            )
        }

        return s
    }

    /// The C++ constraint that selects `m`'s form among the three a generic
    /// ADT declares; "" for a non-generic one, which declares only the form
    /// its facts chose (a constraint on a non-templated function is
    /// ill-formed). Built from the flag names: C++ mechanics, never a Kairo
    /// requires_clause.
    priv fn _adt_requires(self, m: unsafe *Declarations::FunctionDecl, generic: bool) -> string {
        if !generic {
            return ""
        }

        if m->adt_role == Declarations::AdtRole::Dtor {
            var td = LowerTargets::adt_trivial_dtor()
            var ds = LowerTargets::adt_destructible()
            match m->adt_form {
                case Declarations::AdtForm::Trivial {
                    return " requires " + td
                } case Declarations::AdtForm::Body {
                    return " requires (!" + td + " && " + ds + ")"
                } case Declarations::AdtForm::Deleted {
                    return " requires (!" + ds + ")"
                }
            }
        }

        var tc = LowerTargets::adt_trivial_copy()
        var copying = m->adt_role == Declarations::AdtRole::CopyCtor
            || m->adt_role == Declarations::AdtRole::CopyAssign
        var ok = if (copying) => (LowerTargets::adt_copyable()) else => LowerTargets::adt_movable()
        match m->adt_form {
            case Declarations::AdtForm::Trivial {
                return " requires " + tc
            } case Declarations::AdtForm::Body {
                return " requires (!" + tc + " && " + ok + ")"
            } case Declarations::AdtForm::Deleted {
                return " requires (!" + tc + " && !" + ok + ")"
            }
        }
    }

    /// `v`'s enumerator in the record's `__kairo_Tag`, by leaf: the tag
    /// enum's own variant at `v`'s position, never `v`'s name. They differ
    /// when the variant is named like a type parameter (`T` inside
    /// `template <class T>` shadows it), which EnumLayoutLowering::_tag_enum
    /// renames; the tag is positional, so only the spelling moves.
    priv fn _tag_leaf(self,
                      en: unsafe *Declarations::EnumDecl,
                      v:  unsafe *Declarations::EnumVariantDecl) -> string {
        var unsafe *lay = en->adt_layout
        if lay != &null && isa<Declarations::StructDecl>(lay) {
            var unsafe *dc = unsafe (cast<Declarations::StructDecl>(lay) as unsafe *DeclContext)
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                var unsafe *nd = *dc->dc_decls.get(i)
                if nd == &null || !isa<Declarations::EnumDecl>(nd) {
                    continue
                }

                var unsafe *tag = cast<Declarations::EnumDecl>(nd)
                if self._spell->leaf(nd) != LowerTargets::adt_tag_type() {
                    continue
                }

                for var k: usize = 0; k < en->variants.size() && k < tag->variants.size(); ++k {
                    if en->variants[k] == v {
                        return self._spell->leaf(
                            unsafe (tag->variants[k] as unsafe *Decl),
                        )
                    }
                }
            }
        }

        return self._spell->leaf(unsafe (v as unsafe *Decl))
    }

    /// The payload struct holding `v`, by leaf, read off its union member.
    priv fn _payload_leaf(self, v: unsafe *Declarations::EnumVariantDecl) -> string {
        var unsafe *t              = v->adt_member->type_
        var        c: unsafe *Type = &null
        if t != &null && t->canonical != &null {
            c = canon_unqual(t->canonical)
        }

        if c == &null || !isa<RecordType>(c) {
            self._ice(
                self._at(v),
                "InterfaceEmitter: an ADT union member whose type is not its payload struct; EnumLayoutLowering gate failure",
            )
        }

        return self._spell->leaf(cast<RecordType>(c)->decl)
    }

    /// One role function of an ADT's record as C++ text. None has a Kairo
    /// body (EnumLayoutLowering's header says why): the text is a function
    /// of the role, the form and whether the enum is generic, every invented
    /// name from LowerTargets and every other from the record's own decls.
    priv fn _adt_member(self,
                        en:       unsafe *Declarations::EnumDecl,
                        m:        unsafe *Declarations::FunctionDecl,
                        const nm: string,
                        generic:  bool) -> string {
        if Declarations::adt_role_is_nullable(m->adt_role) {
            return self._nullable_member(en, m, nm)
        }

        var tag  = LowerTargets::adt_tag_field()
        var tt   = LowerTargets::adt_tag_type()
        var ds   = LowerTargets::adt_destroy()
        var cf   = LowerTargets::adt_construct_from()
        var nx   = self._adt_noexcept()
        var dreq = self._adt_requires(m, generic) // a defaulted or deleted form: C++ deduces its noexcept.
        // A lang item's site slot (EnumDecl::adt_site_field) travels with the
        // tag: zeroed when a variant is built, copied wherever the tag is.
        var site_init   = ""
        var site_copy   = ""
        var site_assign = ""
        if en->adt_site_field != &null {
            var sn = self._spell->leaf(en->adt_site_field)
            site_init   = ", " + sn + "()"
            site_copy   = ", " + sn + "(o." + sn + ")"
            site_assign = sn.copy() + " = o." + sn + "; "
        }

        var req = nx.copy() + dreq
        var tail = if (m->adt_form == Declarations::AdtForm::Trivial) => (" = default;")
                   else => " = delete;"
        var body = m->adt_form == Declarations::AdtForm::Body
        match m->adt_role {
            case Declarations::AdtRole::VariantCtor {
                if (m->adt_variant as usize) >= en->variants.size() {
                    self._ice(
                        self._at(unsafe (m as unsafe *Decl)),
                        "InterfaceEmitter: an ADT variant constructor past the last variant; EnumLayoutLowering gate failure",
                    )
                }

                var unsafe *v = en->variants[m->adt_variant as usize]
                var vt = "::" + LowerTargets::adt_variant_tag() + f"<{m->adt_variant}>"
                if en->adt_tag_member != &null {
                    // The common prefix: the tag goes in with the payload, or
                    // alone into the tag-only member. `constexpr`: every
                    // field here is trivial and every special member the
                    // defaulted one, so this is what makes the ADT a literal
                    // type, and an `eval` constant of it a C++ constexpr
                    // variable clang accepts.
                    var tv = tt + "::" + self._tag_leaf(en, v)
                    if v->adt_member == &null {
                        return "constexpr " + nm + "(" + vt + ")" + nx + " : " + self._spell->leaf(
                            en->adt_tag_member,
                        ) + "{" + tv + "} {}"
                    }

                    if v->adt_ctor != Declarations::AdtCtorForm::Fields {
                        self._ice(
                            self._at(unsafe (m as unsafe *Decl)),
                            "InterfaceEmitter: a prefix-tagged variant without its field constructor; EnumLayoutLowering::_prefix_ok admits only trivial fields",
                        )
                    }

                    return "constexpr " + self._field_ctor(
                        en,
                        v,
                        nm,
                        vt,
                        "",
                        nx,
                        false,
                        tv + ", ",
                    )
                }

                var init = tag.copy() + "(" + tt + "::" + self._tag_leaf(en, v) + ")" + site_init
                if v->adt_member == &null {
                    return nm.copy() + "(" + vt + ")" + nx + " : " + init + " {}"
                }

                if v->is_pack_expansion {
                    // Element K: the variant's tag plus K (EnumLayoutQuery::
                    // tag_value), built into the union's K-th member.
                    var u  = builtin_info(BuiltinKind::U32)->cxx.copy()
                    var kv = "::" + LowerTargets::adt_variant_tag()
                    // A site slot (the Panic lang item) is the site id
                    // this construction stores (Compiler/Spec/Panic.md#site-ids); a `panic`
                    // passes its own, a widening the one it copies.
                    var sp = ""
                    var si = site_init.copy()
                    if en->adt_site_field != &null {
                        sp = u.copy() + " s, "
                        si = ", " + self._spell->leaf(en->adt_site_field) + "(s)"
                    }

                    return "template <" + u + " K, class F> " + nm + "(" + vt + ", " + kv + "<K>, " + sp + "F&& f)" + nx + " : " + tag + "(" + self._pack_tag(
                        en,
                        v,
                        "K",
                        tt,
                    ) + ")" + si + ", " + self._spell->leaf(
                        v->adt_member,
                    ) + "(" + kv + "<K>{}, static_cast<F&&>(f)) {}"
                }

                // The payload is the callable's prvalue, so the union member
                // is built straight from it: nothing is copied or moved.
                var lam = "template <class F> " + nm + "(" + vt + ", F&& f)" + nx + " : " + init + ", " + self._spell->leaf(
                    v->adt_member,
                ) + "(static_cast<F&&>(f)()) {}"
                match v->adt_ctor {
                    case Declarations::AdtCtorForm::Fields {
                        return self._field_ctor(
                            en,
                            v,
                            nm,
                            vt,
                            init,
                            nx,
                            false,
                            "",
                        )
                    } case Declarations::AdtCtorForm::Both {
                        return self._field_ctor(
                            en,
                            v,
                            nm,
                            vt,
                            init,
                            nx,
                            true,
                            "",
                        ) + " " + lam
                    } default {
                        0
                    }
                }

                return lam
            } case Declarations::AdtRole::CopyCtor {
                if body {
                    return nm.copy() + "(const " + nm + "& o)" + req + " : " + tag + "(o." + tag + ")" + site_copy + " { " + cf + "(o); }"
                }

                return nm.copy() + "(const " + nm + "&)" + dreq + tail
            } case Declarations::AdtRole::MoveCtor {
                if body {
                    return nm.copy() + "(" + nm + "&& o)" + req + " : " + tag + "(o." + tag + ")" + site_copy + " { " + cf + "(static_cast<" + nm + "&&>(o)); }"
                }

                return nm.copy() + "(" + nm + "&&)" + dreq + tail
            } case Declarations::AdtRole::CopyAssign {
                // Destroying first would leave a self-assignment nothing to
                // copy from, so it does nothing instead.
                if body {
                    return nm.copy() + "& operator=(const " + nm + "& o)" + req + " { if (this != &o) { " + ds + "(); " + tag + " = o." + tag + "; " + site_assign + cf + "(o); } return *this; }"
                }

                return nm.copy() + "& operator=(const " + nm + "&)" + dreq + tail
            } case Declarations::AdtRole::MoveAssign {
                if body {
                    return nm.copy() + "& operator=(" + nm + "&& o)" + req + " { if (this != &o) { " + ds + "(); " + tag + " = o." + tag + "; " + site_assign + cf + "(static_cast<" + nm + "&&>(o)); } return *this; }"
                }

                return nm.copy() + "& operator=(" + nm + "&&)" + dreq + tail
            } case Declarations::AdtRole::Dtor {
                if body {
                    return "~" + nm + "()" + req + " { " + ds + "(); }"
                }

                return "~" + nm + "()" + dreq + tail
            } case Declarations::AdtRole::Destroy {
                var s = "void " + ds + "() noexcept { switch (" + tag + ") {"
                for var i: usize = 0; i < en->variants.size(); ++i {
                    var unsafe *v = en->variants[i]
                    if v == &null || v->adt_member == &null || v->is_pack_expansion {
                        continue
                    }

                    var mem = self._spell->leaf(v->adt_member)
                    s += " case " + tt + "::" + self._tag_leaf(
                        en,
                        v,
                    ) + ": " + mem + ".~" + self._payload_leaf(v) + "(); break;"
                }

                return s + " default: " + self._pack_default(en, ds, "") + "break; } }"
            } case Declarations::AdtRole::ConstructFrom {
                // `new` finds the payload struct's own placement form, which
                // needs no <new>.
                var s = "template <class O> void " + cf + "(O&& o)" + nx + " { switch (" + tag + ") {"
                for var i: usize = 0; i < en->variants.size(); ++i {
                    var unsafe *v = en->variants[i]
                    if v == &null || v->adt_member == &null || v->is_pack_expansion {
                        continue
                    }

                    var mem = self._spell->leaf(v->adt_member)
                    s += " case " + tt + "::" + self._tag_leaf(
                        en,
                        v,
                    ) + ": new (&" + mem + ") " + self._payload_leaf(
                        v,
                    ) + "(static_cast<O&&>(o)." + mem + "); break;"
                }

                return s + " default: " + self._pack_default(
                    en,
                    cf,
                    "static_cast<O&&>(o).",
                ) + "break; } }"
            }

            // The tagged form; the niche-filled one is _niche_record's.
            case Declarations::AdtRole::Which {
                return tt + " " + LowerTargets::adt_which() + "() const" + nx + " { return " + tag + "; }"
            } default {
                0
            }
        }

        self._ice(
            self._at(unsafe (m as unsafe *Decl)),
            "InterfaceEmitter: an ADT role function with no rendering; EnumLayoutLowering minted a role this emitter does not know",
        )

        return ""
    }

    /// The `default:` of Destroy / ConstructFrom for a pack-expanded variant
    /// (always last): a tag past its own is element (tag - its tag), which
    /// the union's helper `fn` reaches by that runtime index; `from` is
    /// the source object's prefix for ConstructFrom. "" without one.
    priv fn _pack_default(self,
                          en:         unsafe *Declarations::EnumDecl,
                          const fn_:  string,
                          const from: string) -> string {
        var unsafe *v = DeclFacts::adt_pack_variant(en)
        if v == &null || v->adt_member == &null {
            return ""
        }

        var u = builtin_info(BuiltinKind::U32)->cxx.copy()
        var tag = "static_cast<" + u + ">(" + LowerTargets::adt_tag_field() + ")"
        var mem = self._spell->leaf(v->adt_member)
        var arg = if (from.size() > 0) => (", " + from + mem) else => ""
        if en->adt_explicit_tags {
            // Type-id tags (_pack_tag): the element is the one whose id the
            // tag is, found by a fold over the pack; no match, no payload.
            var e    = self._pack_name(en)
            var tid  = "::" + LowerTargets::type_id()
            var none = "static_cast<" + u + ">(-1)"
            return "{ " + u + " k = 0, i = " + none + "; ((" + tid + "<" + e + "> == " + tag + " ? (void)(i = k) : (void)0, ++k), ...); " + "if (i != " + none + ") { " + mem + "." + fn_ + "(i" + arg + "); } } "
        }

        var tv = f"{v->adt_tag_value}"
        return "if (" + tag + " >= " + tv + ") { " + mem + "." + fn_ + "(" + tag + " - " + tv + arg + "); } "
    }

    /// Variant `v`'s field constructor (AdtCtorForm::Fields / Both): each
    /// field by value, moved into the payload's braced initializer -- a
    /// prvalue initializing the union member, so nothing past the parameter
    /// is copied, and the runtime is the lambda form's: every field is
    /// trivially copied and destroyed (EnumLayoutLowering::_ctor_form), so
    /// the move out of the parameter and its destruction run no code. A
    /// generic ADT's is
    /// constrained on exactly that, which only C++ knows per instance; a
    /// site whose instance is concrete and qualifies calls it
    /// (VariantInitExpr::field_ctor), every other one the lambda form.
    priv fn _field_ctor(self,
                        en:          unsafe *Declarations::EnumDecl,
                        v:           unsafe *Declarations::EnumVariantDecl,
                        const nm:    string,
                        const vt:    string,
                        const init:  string,
                        const nx:    string,
                        constrained: bool,
                        const lead:  string) -> string {
        var unsafe *d    = unsafe (en as unsafe *Decl)
        var        ps    = ""
        var        vals  = ""
        var        moves = ""
        for var i: usize = 0; i < v->payload.size(); ++i {
            var unsafe *f  = v->payload[i]
            var        fn_ = self._spell->leaf(unsafe (f as unsafe *Decl))
            var        t   = self._spell->decl(f->type_, "", &null, d)
            ps += ", " + self._spell->decl(f->type_, fn_, &null, d)
            if i > 0 {
                vals += ", "
                moves += " && "
            }

            vals += if (self._scalar(f->type_)) => (fn_)
                    else => "static_cast<" + t + "&&>(" + fn_ + ")"
            moves += "__is_constructible(" + t + ", " + t + "&&) && __is_trivially_copyable(" + t + ") && __is_trivially_destructible(" + t + ")"
        }

        var req = if (constrained) => (" requires (" + moves + ")") else => ""
        var pre = if (init.size() > 0) => (init.copy() + ", ") else => ""
        return nm.copy() + "(" + vt + ps + ")" + nx + req + " : " + pre + self._spell->leaf(
            v->adt_member,
        ) + "{" + lead + vals + "} {}"
    }

    /// A field type whose move is its copy: a builtin or a pointer, passed
    /// on bare. Anything else is moved out of its parameter.
    prot fn _scalar(self, t: unsafe *Type) -> bool {
        if t == &null || t->canonical == &null {
            return false
        }

        var unsafe *c = canon_unqual(t->canonical)
        return c != &null && (isa<BuiltinType>(c) || isa<PointerType>(c))
    }

    /// ` noexcept` on a role function with a body, unless -funwind: each is
    /// part of a Kairo frame -- a variant constructor runs the payload's
    /// initializers, the transfers run the payloads' -- and a Kairo frame
    /// is noexcept by the same rule a closure is (EmitIR::_closure_expr).
    /// Without it every construction site is an invoke with a terminate
    /// landing pad, and the enclosing function carries a personality.
    prot fn _adt_noexcept(self) -> string {
        if self._cg->opts.unwind {
            return ""
        }

        return " noexcept"
    }

    /// One member of the Null lang item's surface (AdtRole, from
    /// NullDefault on). The enum is `Value { v: T }, Null` and nothing else
    /// (Lib/builtin/module.k): the present variant is the one with a
    /// payload, the null one the one without, and both are found, not
    /// assumed.
    priv fn _nullable_member(self,
                             en:       unsafe *Declarations::EnumDecl,
                             m:        unsafe *Declarations::FunctionDecl,
                             const nm: string) -> string {
        var at = self._at(unsafe (m as unsafe *Decl))
        var tag = LowerTargets::adt_tag_field()
        var tt = LowerTargets::adt_tag_type()
        var some: unsafe *Declarations::EnumVariantDecl = &null
        var none: unsafe *Declarations::EnumVariantDecl = &null
        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v == &null {
                continue
            }

            if v->adt_member != &null {
                some = v
            } else {
                none = v
            }
        }

        if some == &null || none == &null || some->payload.size() != 1 {
            self._ice(
                at,
                "InterfaceEmitter: the Null lang item is not one one-field variant and one empty one",
            )

            return ""
        }

        var unsafe *d        = unsafe (en as unsafe *Decl)
        var        mem       = self._spell->leaf(some->adt_member)
        var unsafe *field    = some->payload[0]
        var        fld       = self._spell->leaf(unsafe (field as unsafe *Decl))
        var        t         = self._spell->decl(field->type_, "", &null, d)
        var        null_tag  = tt.copy() + "::" + self._tag_leaf(en, none)
        var        is_null   = tag.copy() + " == " + null_tag
        var        null_init = " : " + tag + "(" + null_tag + ") {}"
        var present_init = tag.copy() + "(" + tt + "::" + self._tag_leaf(
            en,
            some,
        ) + "), " + mem
        var val = LowerTargets::nullable_value()
        var nx  = self._adt_noexcept()
        match m->adt_role {
            case Declarations::AdtRole::NullDefault {
                return nm.copy() + "()" + nx + null_init
            } case Declarations::AdtRole::NullFrom {
                if m->params.size() != 1 {
                    self._ice(
                        at,
                        "InterfaceEmitter: Null(null_t) without its parameter",
                    )

                    return ""
                }

                return nm.copy() + "(" + self._spell->decl(
                    m->params[0]->type_,
                    "",
                    &null,
                    d,
                ) + ")" + nx + null_init
            }

            // Brace-initialized: the payload struct is an aggregate, so its
            // one field is built straight from the argument. Constrained by
            // the ADT's own flags, because an explicit instantiation defines
            // every member whose constraints hold: an unconstrained copy
            // constructor of a `Null<MoveOnly>` is a hard error there.
            case Declarations::AdtRole::ValueCopy {
                return nm.copy() + "(const " + t + "& v)" + nx + " requires " + LowerTargets::adt_copyable() + " : " + present_init + "{v} {}"
            } case Declarations::AdtRole::ValueMove {
                return nm.copy() + "(" + t + "&& v)" + nx + " requires " + LowerTargets::adt_movable() + " : " + present_init + "{static_cast<" + t + "&&>(v)} {}"
            } case Declarations::AdtRole::IsNull {
                return "bool " + LowerTargets::nullable_is_null() + "() const" + nx + " { return " + is_null + "; }"
            } case Declarations::AdtRole::ValueRef {
                return t + "& " + val + "()" + nx + " { return " + mem + "." + fld + "; }"
            } case Declarations::AdtRole::ValueCref {
                return "const " + t + "& " + val + "() const" + nx + " { return " + mem + "." + fld + "; }"
            } case Declarations::AdtRole::Equal {
                return "bool operator==(const " + nm + "& o) const" + nx + " requires requires (const " + t + "& a) { a == a; } { return " + tag + " == o." + tag + " && ((" + is_null + ") || " + mem + "." + fld + " == o." + mem + "." + fld + "); }"
            } default {
                0
            }
        }

        self._ice(at, "InterfaceEmitter: a Null role with no rendering")
        return ""
    }
}
