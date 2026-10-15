/// --- The Kairo Project ---------------- Sema/Lower/VariantInitLowering.k --- ///
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Type::TypeUtil::*;
import Sema::Lower::LowerSynth::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::Context::DeclContext::*;
import AST::Node::Base::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import Token::Token::*;
import Location::SourceRange::*;

class VariantInitLowering derives ASTWriter::<VariantInitLowering> {
    pub var sc: *SemaContext;
    priv var tu: TypeUtil;
    priv var synth: LowerSynth;

    fn VariantInitLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.tu    = TypeUtil(sc);
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter::<VariantInitLowering>::run(self.sc->tu);
    }

    // --- entry points: the three nodes a construction is written as ----------------

    fn transform_named_initializer_expr(self, n: *NamedInitializerExpr) -> *Expr {
        var out = ASTWriter::<VariantInitLowering>::transform_named_initializer_expr(n);
        if n->variant_decl == &null { return out; }
        return self._lower(static_cast::<*Expr>(n), n->variant_decl, n->fields);
    }

    fn transform_chain_expr(self, n: *ChainExpr) -> *Expr {
        var out = ASTWriter::<VariantInitLowering>::transform_chain_expr(n);
        if n->variant_decl == &null { return out; }
        return self._lower(static_cast::<*Expr>(n), n->variant_decl, create_empty_frozen_list::<InitField>());
    }

    fn transform_named_ident_expr(self, n: *NamedIdentExpr) -> *Expr {
        var out = ASTWriter::<VariantInitLowering>::transform_named_ident_expr(n);
        if n->variant_decl == &null { return out; }
        return self._lower(static_cast::<*Expr>(n), n->variant_decl, create_empty_frozen_list::<InitField>());
    }

    // --- the rewrite -------------------------------------------------------------------

    /// \p n built the variant \p vd from \p fields (none for a name). Left as
    /// it is when poisoned or untyped: a conversion checked after X typed it
    /// (a var's declared type) can poison it, and the pipeline then stops
    /// before codegen.
    priv fn _lower(self, n: *Expr, vd: *Decl, fields: FrozenList::<InitField>) -> *Expr {
        if n->is_poisoned() || (n->type_ == &null) { return n; }
        var v   = cast::<EnumVariantDecl>(vd);
        var en  = self._enum_of(v);
        var idx = self._index_of(en, v);

        if !en->is_adt {
            ICE_IF((fields.size() > 0), "VariantInitLowering: a plain enum's variant with fields; ControlTyping::_check_variant rejects braces on it");
            var id = NamedIdentExpr::create(self.ctx, n->range, self.synth.ident(n->range, self.tu.decl_name(vd)));
            id->resolved_decl = vd;
            id->adopt_sema(n);
            return static_cast::<*Expr>(id);
        }

        var np = v->payload.size();
        ICE_IF((fields.size() != np), "VariantInitLowering: field count differs from the payload; ControlTyping::_check_variant records one field per payload field");
        var vi = VariantInitExpr::create(self.ctx, n->range, static_cast::<*Decl>(en), u32(idx));
        var fl = self.list_builder::<*Expr>();
        var ol = self.list_builder::<u32>();
        for var k: usize = 0; k < np; ++k {
            var want = static_cast::<*Decl>(v->payload[k]);
            var at: i32 = -1;
            for var i: usize = 0; i < fields.size(); ++i {
                if fields.get(i)->field_decl == want { at = i32(i); break; }
            }
            ICE_IF((at < 0), "VariantInitLowering: a payload field no initializer fills; ControlTyping::_check_variant matched every one");
            fl.push(fields.get(usize(at))->value);
            ol.push(u32(at));
        }
        fl.freeze_into(&(vi->fields));
        ol.freeze_into(&(vi->source_order));
        vi->adopt_sema(n);
        return static_cast::<*Expr>(vi);
    }

    /// The enum \p v belongs to. X records the pattern enum's own variant, so
    /// this is the pattern decl, whose list positions are the tags.
    priv fn _enum_of(self, v: *EnumVariantDecl) -> *EnumDecl {
        var dc = reinterpret_cast::<*DeclContext>(v->semantic_dc);
        var en: *EnumDecl = &null;
        if dc != &null { en = dyn_cast::<EnumDecl>(dc->owner_decl()); }
        ICE_IF((en == &null), "VariantInitLowering: a variant with no owning enum");
        return en;
    }

    /// \p v's position in \p en's list: its tag.
    priv fn _index_of(self, en: *EnumDecl, v: *EnumVariantDecl) -> usize {
        for var i: usize = 0; i < en->variants.size(); ++i {
            if en->variants[i] == v { return i; }
        }
        ICE_FAIL("VariantInitLowering: a variant missing from its own enum's list");
        return 0;
    }
}

