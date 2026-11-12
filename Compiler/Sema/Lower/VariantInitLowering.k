/// --- The Kairo Project ------------- Sema/Lower/VariantInitLowering.k --- ///
///
///   \brief An enum variant construction becomes the node EmitIR renders.
///
///   \detail
///     X checked each construction against its variant's payload and wrote
///     what it found on the node the construction was written as:
///     `variant_decl`, the EnumVariantDecl, on the NamedInitializerExpr of
///     `E::V { .. }` / `.V { .. }` / `.V`, or on the ChainExpr /
///     NamedIdentExpr of a payload-less ADT variant named as a value
///     (`Opt::None`); and on each initializer field, `InitField::field_decl`,
///     the payload field it fills. This pass decides nothing: it reads those
///     facts and replaces the node.
///
///       Shape::Rect { h: g(), w: n }    VariantInitExpr Shape::Rect
///                                         fields        n, g()   declaration order
///                                         source_order  1, 0     where each was written
///       Opt::None                       VariantInitExpr Opt::None, no fields
///       .North   (Dir, a plain enum)    NamedIdentExpr North, typed Dir
///
///     Only an ADT variant becomes a VariantInitExpr, which EmitIR renders as
///     the enum's tagged constructor. A plain enum's variant is a value, not
///     a construction: X records one only when it is written `.V`, which has
///     no name EmitIR could spell, and it becomes the enumerator's name,
///     which EmitIR spells qualified, as it does a `Dir::North` chain.
///
///     The replacement keeps the node's range, type (the enum; its instance
///     for a generic enum), dependence and value category. The children are
///     rewritten first, so a construction nested in a payload is replaced
///     too.
///
///   \par Evaluation order
///     `fields` is in declaration order, the order a C++ braced list runs;
///     `source_order` keeps the order they were written in, the order Kairo
///     runs them. SequenceLowering reconciles the two.
///
///   Phase: LOWER, first. X's facts are read on the nodes X wrote them on,
///   before any pass rebuilds an initializer or a chain, and every later pass
///   sees one node kind for a construction: SequenceLowering orders its
///   payload, and nothing else has to know the forms it was written in.
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
ffi "c++" import "vector"

import AST::ASTSupport::{
    FrozenList,
    create_empty_frozen_list,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
}
import AST::Node::Declarations::{
    EnumDecl,
    EnumVariantDecl,
}
import AST::Node::Expressions::{
    InitField,
    NamedInitializerExpr,
    VariantInitExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Visitor::ASTWriter::ASTWriter
import Sema::Lower::LowerStep::LowerStep
import Sema::Lower::LowerSynth::LowerSynth
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::TypeUtil::TypeUtil
import Sema::Type::VariadicEnum::VariadicEnum

pub class VariantInitLowering derives ASTWriter<VariantInitLowering> {
    pub var  sc:    unsafe *SemaContext
    priv var tu:    TypeUtil
    priv var synth: LowerSynth

    fn VariantInitLowering(self, sc: unsafe *SemaContext) {
        self.sc    = sc
        self.ctx   = sc->ctx
        self.tu    = TypeUtil(sc)
        self.synth = LowerSynth(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        self.sc->begin_lower(LowerStep::VariantInit)
        if self.sc->tu == &null {
            return
        }

        ASTWriter<VariantInitLowering>::run(self, self.sc->tu)
    }

    /// # entry points: the three nodes a construction is written as

    fn transform_named_initializer_expr(self, n: unsafe *NamedInitializerExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<VariantInitLowering>::transform_named_initializer_expr(
            self,
            n,
        )

        if n->variant_decl == &null {
            return out
        }

        return self._lower(
            unsafe (n as unsafe *Expr),
            n->variant_decl,
            n->fields,
        )
    }

    fn transform_chain_expr(self, n: unsafe *ChainExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<VariantInitLowering>::transform_chain_expr(
            self,
            n,
        )

        if n->variant_decl == &null {
            return out
        }

        return self._lower(
            unsafe (n as unsafe *Expr),
            n->variant_decl,
            create_empty_frozen_list<InitField>(),
        )
    }

    fn transform_named_ident_expr(self, n: unsafe *NamedIdentExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<VariantInitLowering>::transform_named_ident_expr(
            self,
            n,
        )

        if n->variant_decl == &null {
            return out
        }

        return self._lower(
            unsafe (n as unsafe *Expr),
            n->variant_decl,
            create_empty_frozen_list<InitField>(),
        )
    }

    /// # the rewrite

    /// \p n built the variant \p vd from \p fields (none for a name). Left as
    /// it is when poisoned or untyped: a conversion checked after X typed it
    /// (a var's declared type) can poison it, and the pipeline then stops
    /// before codegen.
    priv fn _lower(self,
                   n:      unsafe *Expr,
                   vd:     unsafe *Decl,
                   fields: FrozenList<InitField>) -> unsafe *Expr {
        if n->is_poisoned() || n->type_ == &null {
            return n
        }

        var unsafe *v  = cast<EnumVariantDecl>(vd)
        var unsafe *en = self._enum_of(v)
        var        idx = self._index_of(en, v)

        if !en->is_adt {
            if fields.size() > 0 {
                kairo::std::ice_fail(
                    "VariantInitLowering: a plain enum's variant with fields; ControlTyping::_check_variant rejects braces on it",
                )
            }

            var unsafe *id = NamedIdentExpr::create(
                self.ctx,
                n->range,
                self.synth.ident(n->range, self.tu.decl_name(vd)),
            )

            id->resolved_decl = vd
            id->adopt_sema(n)
            return id
        }

        var np = v->payload.size()
        if fields.size() != np {
            kairo::std::ice_fail(
                "VariantInitLowering: field count differs from the payload; ControlTyping::_check_variant records one field per payload field",
            )
        }

        var unsafe *vi = VariantInitExpr::create(
            self.ctx,
            n->range,
            en,
            idx as u32,
        )

        var fl = self.list_builder<unsafe *Expr>()
        var ol = self.list_builder<u32>()
        for var k: usize = 0; k < np; ++k {
            var unsafe *want     = unsafe (v->payload[k] as unsafe *Decl)
            var        at:   i32 = -1
            for var i: usize = 0; i < fields.size(); ++i {
                if fields.get(i)->field_decl == want {
                    at = (i as i32)
                    break
                }
            }

            if at < 0 {
                kairo::std::ice_fail(
                    "VariantInitLowering: a payload field no initializer fills; ControlTyping::_check_variant matched every one",
                )
            }

            fl.push(fields.get(at as usize)->value)
            ol.push(at as u32)
        }

        fl.freeze_into(&vi->fields)
        ol.freeze_into(&vi->source_order)
        // A pack-expanded variant: the element X picked, and its type.
        var unsafe *ni = dyn_cast<NamedInitializerExpr>(n)
        if v->is_pack_expansion {
            if ni == &null || ni->variant_pack < 0 {
                kairo::std::ice_fail(
                    "VariantInitLowering: a pack-expanded variant built with no element picked; ControlTyping::_pick_element records one",
                )
            }

            var es = cxx::std::vector<unsafe *Type>()
            var ok = VariadicEnum(self.sc).elems(n->type_, unsafe &es)
            if !ok || (ni->variant_pack as usize) >= es.size() {
                kairo::std::ice_fail(
                    "VariantInitLowering: the picked element is not one of the instance's",
                )
            }

            vi->pack_index = ni->variant_pack
            vi->pack_elem  = es[ni->variant_pack as usize]
        }

        vi->adopt_sema(n)
        return vi
    }

    /// The enum \p v belongs to. X records the pattern enum's own variant, so
    /// this is the pattern decl, whose list positions are the tags.
    priv fn _enum_of(self, v: unsafe *EnumVariantDecl) -> unsafe *EnumDecl {
        var unsafe *dc                  = v->semantic_dc
        var        en: unsafe *EnumDecl = &null
        if dc != &null {
            en = dyn_cast<EnumDecl>(dc->owner_decl())
        }

        if en == &null {
            kairo::std::ice_fail(
                "VariantInitLowering: a variant with no owning enum",
            )
        }

        return en
    }

    /// \p v's position in \p en's list: its tag.
    priv fn _index_of(self, en: unsafe *EnumDecl, v: unsafe *EnumVariantDecl) -> usize {
        for var i: usize = 0; i < en->variants.size(); ++i {
            if en->variants[i] == v {
                return i
            }
        }

        kairo::std::ice_fail(
            "VariantInitLowering: a variant missing from its own enum's list",
        )
    }
}
