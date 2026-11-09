/// --- The Kairo Project ---------------- Sema/Lower/CopyMoveLowering.k --- ///
///
///   \brief Select and insert @copy / @move constructors at each use.
///
///   \detail
///     Replaces C++'s rule of five: every initialization, assignment, and
///     argument pass resolves to exactly one of the annotated
///     constructors, or to a trivial bitwise copy when the type permits
///     it. The destroy half needs no pass: the emitted C++ destroys
///     every local at scope exit itself.
///
///     Done so far: the moves. A MOVE value passed, initialized from,
///     assigned or returned is moved (Doc: Ownership, Function Parameters),
///     and Kairo has no std::move to say so; C++ copies an lvalue unless it
///     is cast, and the copy constructor of a MOVE record is deleted. Each
///     such site MoveCheck recorded (SemaContext::move_sites) becomes
///
///       count_words(name)   ->   count_words(name as T&&)
///
///     which EmitIR spells static_cast<T&&>(name). MoveCheck is the one
///     place that decides it, alongside use-after-move, so what C++ moves
///     and what the checker counts as moved cannot drift apart. A COPY value
///     needs nothing here: C++ copies it through the record's own copy
///     constructor.
///
///   Phase: LOWER, after FieldInitLowering and before every pass that
///   rebuilds an expression, so each recorded node is still the one
///   MoveCheck saw.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Node::Base::Expr
import AST::Node::CanonicalNodes::canon_unqual
import AST::Node::Expressions::CastMode
import AST::Visitor::ASTWriter::ASTWriter
import Sema::Lower::LowerSynth::LowerSynth
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}

pub class CopyMoveLowering derives ASTWriter<CopyMoveLowering> {
    pub var  sc:    unsafe *SemaContext
    priv var synth: LowerSynth

    fn CopyMoveLowering(self, sc: unsafe *SemaContext) {
        self.sc    = sc
        self.ctx   = sc->ctx
        self.synth = LowerSynth(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        if self.sc->tu == &null {
            return
        }

        if self.sc->move_sites.empty() {
            return
        }

        ASTWriter<CopyMoveLowering>::run(self, self.sc->tu)
    }

    /// Membership is read off the node as it arrives: the children's own
    /// rewrite may hand back a new one.
    fn transform_expr(self, e: unsafe *Expr) -> unsafe *Expr {
        if e == &null {
            return e
        }

        var        site = self.sc->move_sites.count(e as usize as u64) != 0
        var unsafe *out = ASTWriter<CopyMoveLowering>::transform_expr(self, e)
        if !site || out == &null || out->type_ == &null {
            return out
        }

        var unsafe *c = self.synth.cast_to(
            out->range,
            out,
            self.sc->types->cxx_rref(canon_unqual(out->type_)),
            CastMode::Default,
        )

        c->value_category = Expr::ValueCategory::XValue
        return c
    }
}
