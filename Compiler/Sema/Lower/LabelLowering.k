/// --- The Kairo Project --------------------- Sema/Lower/LabelLowering.k --- ///
///
///   \brief `break L` and `continue L` become gotos; the label on the loop
///          goes away.
///
///   \detail
///       L: while c { BODY }
///
///     becomes
///
///       while c { { BODY } __kairo_cont<K>_L:; }
///       __kairo_brk<K>_L:;
///
///     `continue L` is `goto __kairo_cont<K>_L`: the end of the body, which
///     is where an unlabeled `continue` goes too (the update clause of a
///     C-style `for` still runs; IterLowering's loops advance before the
///     body, so they need nothing after it). `break L` is
///     `goto __kairo_brk<K>_L`, the statement after the loop.
///
///     The body is wrapped in its own block so the continue label sits
///     after every declaration the body makes: no goto crosses an
///     initialization. The break label sits after the loop in the same
///     list, which declares nothing between the two.
///
///     A label is emitted only when something jumps to it; a labeled loop
///     no `break L`/`continue L` names is just the loop.
///
///   \par Names
///     LowerTargets::loop_break / loop_continue. `K` is a per-function
///     counter: C++ labels are function-scoped, and Kairo lets two loops in
///     one function reuse a label name.
///
///   \par Scope
///     `while`, `loop`, C-style `for`, and the `while` loops IterLowering
///     mints (it keeps the label on the loop it made). JumpLabelCheck has
///     already proved every `break L`/`continue L` names an enclosing loop
///     of this function; a miss here is an ICE.
///
///   Phase: LOWER, after IterLowering (labels on its loops) and
///   MatchLowering (a `break L` in an arm is still a `break L` there).
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
import AST::ASTSupport::*;
import AST::LangItems::*;
import AST::Node::Base::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import Token::Token::*;
import Location::SourceRange::*;

__inline_cpp("
#define ASTWriter_LabelLowering ASTWriter<LabelLowering>
");

/// A labeled loop being walked.
struct LoopLabel {
    var name:      string;
    var brk:       Token;
    var cont:      Token;
    var brk_used:  bool = false;
    var cont_used: bool = false;
}

class LabelLowering derives ASTWriter::<LabelLowering> {
    pub var sc: *SemaContext;
    priv var synth: LowerSynth;
    priv var _loops: vec::<LoopLabel>;   ///< innermost last.
    priv var _depth: usize = 0;          ///< _loops in use; entries past it are stale.
    priv var _count: usize = 0;          ///< labeled loops lowered in this function.

    fn LabelLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter_LabelLowering::run(self.sc->tu);
    }

    fn transform_function_decl(self, n: *FunctionDecl) -> vec::<*Decl> {
        var saved = self._count;
        self._count = 0;
        var out = ASTWriter_LabelLowering::transform_function_decl(n);
        self._count = saved;
        return out;
    }

    fn transform_labeled_stmt(self, n: *LabeledStmt) -> vec::<*Stmt> {
        var name = self.sc->ctx->get_spelling(n->label);
        var e = LoopLabel{};
        e.name = name;
        e.brk  = self.synth.ident(n->label.range, LowerTargets::loop_break(self._count, name));
        e.cont = self.synth.ident(n->label.range, LowerTargets::loop_continue(self._count, name));
        self._count += 1;
        self._push(e);

        var inner = self.transform_stmt_scalar(n->inner);
        var top = self._loops[self._depth - 1];
        self._depth -= 1;

        if top.cont_used { self._end_body(inner, top.cont); }
        var out = vec::<*Stmt>();
        out.push_back(inner);
        if top.brk_used {
            out.push_back(static_cast::<*Stmt>(LabelIntrinsicStmt::create(self.ctx, n->range, top.brk)));
        }
        return out;
    }

    fn transform_break_stmt(self, n: *BreakStmt) -> vec::<*Stmt> {
        if !n->has_label { return self._one_stmt(n); }
        var i = self._find(n->label);
        self._loops[i].brk_used = true;
        return self._one_stmt(static_cast::<*Stmt>(JumpIntrinsicStmt::create(self.ctx, n->range, self._loops[i].brk)));
    }

    fn transform_continue_stmt(self, n: *ContinueStmt) -> vec::<*Stmt> {
        if !n->has_label { return self._one_stmt(n); }
        var i = self._find(n->label);
        self._loops[i].cont_used = true;
        return self._one_stmt(static_cast::<*Stmt>(JumpIntrinsicStmt::create(self.ctx, n->range, self._loops[i].cont)));
    }

    // --- helpers -------------------------------------------------------------------

    priv fn _push(self, e: LoopLabel) {
        if self._depth < self._loops.size() { self._loops[self._depth] = e; }
        else { self._loops.push_back(e); }
        self._depth += 1;
    }

    /// The innermost enclosing labeled loop named like \p label.
    priv fn _find(self, label: Token) -> usize {
        var name = self.sc->ctx->get_spelling(label);
        var i = self._depth;
        while i > 0 {
            i -= 1;
            if self._loops[i].name == name { return i; }
        }
        ICE_FAIL(f"LabelLowering: no enclosing loop labeled '{name}'; JumpLabelCheck gate failure");
        return 0;
    }

    /// `body` becomes `{ { body } cont:; }`.
    priv fn _end_body(self, loop: *Stmt, cont: Token) {
        var body: *CompoundStmt = &null;
        if isa::<WhileLoopStmt>(loop)       { body = cast::<WhileLoopStmt>(loop)->body; }
        else if isa::<LoopStmt>(loop)       { body = cast::<LoopStmt>(loop)->body; }
        else if isa::<IndexedForStmt>(loop) { body = cast::<IndexedForStmt>(loop)->body; }
        ICE_IF(body == &null, "LabelLowering: a label on a statement that is not a loop IterLowering or the parser makes");

        var lb = self.list_builder::<*Stmt>();
        lb.push(static_cast::<*Stmt>(body));
        lb.push(static_cast::<*Stmt>(LabelIntrinsicStmt::create(self.ctx, body->range, cont)));
        var outer = CompoundStmt::create(self.ctx, body->range);
        lb.freeze_into(&(outer->body));

        if isa::<WhileLoopStmt>(loop)  { cast::<WhileLoopStmt>(loop)->body = outer; }
        else if isa::<LoopStmt>(loop)  { cast::<LoopStmt>(loop)->body = outer; }
        else                           { cast::<IndexedForStmt>(loop)->body = outer; }
    }
}

__inline_cpp("
#undef ASTWriter_LabelLowering
");