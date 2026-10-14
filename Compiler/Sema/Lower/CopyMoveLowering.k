/// --- The Kairo Project ---------------- Sema/Lower/CopyMoveLowering.k --- ///
///
///   \brief Select and insert @copy / @move constructors at each use.
///
///   \detail
///     Replaces C++'s rule of five: every initialization, assignment, and
///     argument pass resolves to exactly one of the annotated
///     constructors, or to a trivial bitwise copy when the type permits
///     it. Pairs with DestructorInsertion, which owns the destroy half.
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Lower::LowerSynth::*;
import AST::Visitor::ASTWriter::*;
import AST::Node::Base::*;
import AST::Node::Expressions::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;

__inline_cpp("
#define ASTWriter_CopyMoveLowering ASTWriter<CopyMoveLowering>
");

class CopyMoveLowering derives ASTWriter::<CopyMoveLowering> {
    pub var sc: *SemaContext;
    priv var synth: LowerSynth;

    fn CopyMoveLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        if self.sc->move_sites.empty() { return; }
        ASTWriter_CopyMoveLowering::run(self.sc->tu);
    }

    /// Membership is read off the node as it arrives: the children's own
    /// rewrite may hand back a new one.
    fn transform_expr(self, e: *Expr) -> *Expr {
        if e == &null { return e; }
        var site = self.sc->move_sites.count(reinterpret_cast::<u64>(e)) != 0;
        var out  = ASTWriter_CopyMoveLowering::transform_expr(e);
        if (!site) || (out == &null) || (out->type_ == &null) { return out; }
        var c = self.synth.cast_to(out->range, out, self.sc->types->cxx_rref(canon_unqual(out->type_)), CastMode::Default);
        c->value_category = Expr::ValueCategory::XValue;
        return c;
    }
}

__inline_cpp("
#undef ASTWriter_CopyMoveLowering
");
