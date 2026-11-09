/// --- The Kairo Project --------------------- Sema/Type/VariadicEnum.k --- ///
///
///   \brief A pack-expanded variant (`Err { e: E }...`) read at one instance:
///          which elements it has, what each one's payload holds, and which
///          one a payload type picks (Compiler/Spec/Panic.md#the-result-type, enums-adt.mdx).
///
///   \detail
///     The variant is declared once; at `R<i32, string, f64>` it is one
///     variant per pack element, `Err { e: string }` and `Err { e: f64 }`.
///     The pack is a set (decl_dedup_pack_args), so element k is one
///     variant and its EXPANDED index is the variant's position plus k
///     (adt_variant_at): that is the tag it is stored with and the index
///     every pattern and layout question uses.
///
///     A payload field that names the pack names it bare (`e: E`;
///     PackChecking rejects `*E` and the like): at element k its type is
///     the element. Any other field reads through the instance as any
///     payload does.
///
///     Patterns and constructions tell the expansions apart by payload
///     type, the rule `catch e: E` uses (pick): the pack fields' types must
///     equal one element's exactly; failing that, the one element every
///     value converts to; anything else is an error naming the candidates.
///     Only at a concrete type: a dependent one (a generic body) is the
///     instance's question, which needs M2.
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

import AST::DeclFacts::{
    adt_pack_param,
    adt_pack_variant,
}
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::canon_unqual
import AST::Node::Casting::dyn_cast
import AST::Node::Declarations::{
    EnumDecl,
    EnumVariantDecl,
    FieldDecl,
}
import AST::Node::Types::GenericParamType
import Sema::SemaContext::SemaContext
import Sema::Type::ArgumentDeduction::Deduction
import Sema::Type::TypeUtil::TypeUtil

pub class VariadicEnum {
    pub var  sc: unsafe *SemaContext
    priv var tu: TypeUtil

    fn VariadicEnum(self) {
        self.sc = &null
    }

    fn VariadicEnum(self, sc: unsafe *SemaContext) {
        self.sc = sc
        self.tu = TypeUtil(sc)
    }

    /// The ADT pattern behind \p t when it has a pack-expanded variant.
    fn enum_of(self, t: unsafe *Type) -> unsafe *EnumDecl {
        if t == &null {
            return &null
        }

        var unsafe *d = self.tu.record_decl(self.tu.as_value(t))
        if d == &null {
            return &null
        }

        var unsafe *en = dyn_cast<EnumDecl>(self.tu.pattern_of(d))
        if en == &null || !en->is_adt || adt_pack_variant(en) == &null {
            return &null
        }

        return en
    }

    /// The pack's elements at instance \p t, in \p out; false when \p t is
    /// no variadic ADT, or a dependent one (whose elements C++ decides).
    fn elems(self, t: unsafe *Type, out: unsafe *cxx::std::vector<unsafe *Type>) -> bool {
        var unsafe *en = self.enum_of(t)
        if en == &null {
            return false
        }

        var unsafe *v = canon_unqual(self.tu.as_value(t))
        if v == &null || v->is_dependent() || v->is_instantiation_dependent() {
            return false
        }

        var at   = adt_pack_param(en)
        var args = self.tu.record_args(v)
        for var i: usize = at; i < args.size(); ++i {
            out->push_back(args[i])
        }

        return true
    }

    /// How many constructors \p en has at \p t: its variants, the
    /// pack-expanded one counted once per element (none for an empty pack).
    fn ctor_count(self, en: unsafe *EnumDecl, t: unsafe *Type) -> usize {
        if en == &null {
            return 0
        }

        var n = en->variants.size()
        if adt_pack_variant(en) == &null {
            return n
        }

        var es = cxx::std::vector<unsafe *Type>()
        if !self.elems(t, unsafe &es) {
            return n
        }

        return n - 1 + es.size()
    }

    /// \p f names the pack, bare: its type at element k is the element.
    fn is_pack_field(self, f: unsafe *FieldDecl) -> bool {
        if f == &null || f->type_ == &null || f->type_->canonical == &null {
            return false
        }

        var unsafe *g = dyn_cast<GenericParamType>(canon_unqual(f->type_->canonical))
        return g != &null && g->is_pack
    }

    /// Payload field \p f's type at element \p k of instance \p rec (any
    /// field of a variadic ADT: one that is not the pack reads through the
    /// instance's other arguments).
    fn field_at(self, rec: unsafe *Type, f: unsafe *FieldDecl, k: usize) -> unsafe *Type {
        if f == &null || f->type_ == &null || f->type_->canonical == &null {
            return &null
        }

        if self.is_pack_field(f) {
            var es = cxx::std::vector<unsafe *Type>()
            if !self.elems(rec, unsafe &es) || k >= es.size() {
                return &null
            }

            return es[k]
        }

        var ded = Deduction(self.sc, &null)
        return ded.member_through(rec, f->type_->canonical)
    }

    /// `Err { e: string }, Err { e: f64 }`: every expansion of \p v at \p
    /// rec, for a note naming the candidates.
    fn describe(self, rec: unsafe *Type, v: unsafe *EnumVariantDecl) -> string {
        var es = cxx::std::vector<unsafe *Type>()
        if !self.elems(rec, unsafe &es) {
            return ""
        }

        var vn = self.tu.decl_name(unsafe (v as unsafe *Decl))
        var s  = ""
        for var k: usize = 0; k < es.size(); ++k {
            if k > 0 {
                s += ", "
            }

            s += vn + " { "
            for var j: usize = 0; j < v->payload.size(); ++j {
                if j > 0 {
                    s += ", "
                }

                var unsafe *ft = self.field_at(rec, v->payload[j], k)
                var        fts = "?"
                if ft != &null {
                    fts = self.tu.str(ft)
                }

                s += self.tu.decl_name(v->payload[j]) + ": " + fts
            }

            s += " }"
        }

        return s
    }

    /// The element whose type is exactly \p t, or -1.
    fn exact(self, rec: unsafe *Type, t: unsafe *Type) -> i32 {
        var es = cxx::std::vector<unsafe *Type>()
        if t == &null || !self.elems(rec, unsafe &es) {
            return -1
        }

        var unsafe *want = canon_unqual(self.tu.as_value(t))
        for var k: usize = 0; k < es.size(); ++k {
            if canon_unqual(es[k]) == want {
                return k as i32
            }
        }

        return -1
    }
}
