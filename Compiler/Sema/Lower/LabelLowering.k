/// --- The Kairo Project ------------------- Sema/Lower/LabelLowering.k --- ///
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::LangItems::LowerTargets
import AST::Node::Base::{
    Decl,
    Stmt,
}
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Declarations::FunctionDecl
import AST::Node::Statements::{
    BreakStmt,   CompoundStmt, ContinueStmt,  IndexedForStmt, JumpIntrinsicStmt, LabelIntrinsicStmt,
    LabeledStmt, LoopStmt,     WhileLoopStmt,
}
import AST::Visitor::ASTWriter::ASTWriter
import Sema::Lower::LowerSynth::LowerSynth
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Token::Token::Token

/// A labeled loop being walked.
pub struct LoopLabel {
    var name:      string
    var brk:       Token
    var cont:      Token
    var brk_used:  bool   = false
    var cont_used: bool   = false
}

pub class LabelLowering derives ASTWriter<LabelLowering> {
    pub var  sc:     unsafe *SemaContext
    priv var synth:  LowerSynth
    priv var _loops: cxx::std::vector<LoopLabel>     ///< innermost last.
    priv var _depth: usize                       = 0 ///< _loops in use; entries past it are stale.
    priv var _count: usize                       = 0 ///< labeled loops lowered in this function.

    fn LabelLowering(self, sc: unsafe *SemaContext) {
        self.sc    = sc
        self.ctx   = sc->ctx
        self.synth = LowerSynth(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        if self.sc->tu == &null {
            return
        }

        ASTWriter<LabelLowering>::run(self, self.sc->tu)
    }

    fn transform_function_decl(self, n: unsafe *FunctionDecl) -> cxx::std::vector<unsafe *Decl> {
        var saved = self._count
        self._count = 0
        var out = ASTWriter<LabelLowering>::transform_function_decl(self, n)
        self._count = saved
        return out
    }

    fn transform_labeled_stmt(self, n: unsafe *LabeledStmt) -> cxx::std::vector<unsafe *Stmt> {
        var name = self.sc->ctx->get_spelling(n->label)
        var e    = LoopLabel{}
        e.name = name
        e.brk  = self.synth.ident(n->label.range, LowerTargets::loop_break(self._count, name))
        e.cont = self.synth.ident(n->label.range, LowerTargets::loop_continue(self._count, name))
        self._count += 1
        self._push(e)

        var unsafe *inner = self.transform_stmt_scalar(n->inner)
        var        top    = self._loops[self._depth - 1]
        self._depth -= 1

        if top.cont_used {
            self._end_body(inner, top.cont)
        }

        var out = cxx::std::vector<unsafe *Stmt>()
        out.push_back(inner)
        if top.brk_used {
            out.push_back(LabelIntrinsicStmt::create(self.ctx, n->range, top.brk))
        }

        return out
    }

    fn transform_break_stmt(self, n: unsafe *BreakStmt) -> cxx::std::vector<unsafe *Stmt> {
        if !n->has_label {
            return self._one_stmt(n)
        }

        var i = self._find(n->label)
        self._loops[i].brk_used = true
        return self._one_stmt(JumpIntrinsicStmt::create(self.ctx, n->range, self._loops[i].brk))
    }

    fn transform_continue_stmt(self, n: unsafe *ContinueStmt) -> cxx::std::vector<unsafe *Stmt> {
        if !n->has_label {
            return self._one_stmt(n)
        }

        var i = self._find(n->label)
        self._loops[i].cont_used = true
        return self._one_stmt(JumpIntrinsicStmt::create(self.ctx, n->range, self._loops[i].cont))
    }

    /// # helpers

    priv fn _push(self, const e: LoopLabel) {
        if self._depth < self._loops.size() {
            self._loops[self._depth] = e
        } else {
            self._loops.push_back(e)
        }

        self._depth += 1
    }

    /// The innermost enclosing labeled loop named like \p label.
    priv fn _find(self, label: Token) -> usize {
        var name = self.sc->ctx->get_spelling(label)
        var i    = self._depth
        while i > 0 {
            i -= 1
            if self._loops[i].name == name {
                return i
            }
        }

        kairo::std::ice_fail(
            f"LabelLowering: no enclosing loop labeled '{name}'; JumpLabelCheck gate failure",
        )
    }

    /// `body` becomes `{ { body } cont:; }`.
    priv fn _end_body(self, #loop: unsafe *Stmt, cont: Token) {
        var body: unsafe *CompoundStmt = &null
        if isa<WhileLoopStmt>(#loop) {
            body = cast<WhileLoopStmt>(#loop)->body
        } else if isa<LoopStmt>(#loop) {
            body = cast<LoopStmt>(#loop)->body
        } else if isa<IndexedForStmt>(#loop) {
            body = cast<IndexedForStmt>(#loop)->body
        }

        if body == &null {
            kairo::std::ice_fail(
                "LabelLowering: a label on a statement that is not a loop IterLowering or the parser makes",
            )
        }

        var lb = self.list_builder<unsafe *Stmt>()
        lb.push(body)
        lb.push(LabelIntrinsicStmt::create(self.ctx, body->range, cont))
        var unsafe *outer = CompoundStmt::create(self.ctx, body->range)
        lb.freeze_into(&outer->body)

        if isa<WhileLoopStmt>(#loop) {
            cast<WhileLoopStmt>(#loop)->body = outer
        } else if isa<LoopStmt>(#loop) {
            cast<LoopStmt>(#loop)->body = outer
        } else {
            cast<IndexedForStmt>(#loop)->body = outer
        }
    }
}
