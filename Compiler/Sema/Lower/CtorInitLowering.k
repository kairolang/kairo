/// --- The Kairo Project -------------- Sema/Lower/CtorInitLowering.k --- ///
///
///   \brief A constructor that initializes a field in place (a const one,
///          one whose type has no default, an array; CtorInitCheck) has its
///          body cut in two at CtorInitCheck's frontier.
///
///   \detail
///       fn F(self, x: i32) { if x < 0 { self.x = 0 } else { self.x = x }  self.go() }
///     ->
///       fn F(self, x: i32) { { if x < 0 { self.x = 0 } else { self.x = x } }  { self.go() } }
///                            ^ S_pre (body[0])                              ^ S_post (body[1])
///
///     That is the whole rewrite: two blocks, nothing renamed, nothing
///     minted. EmitIR writes body[0] as the body of a static pre-function
///     that fills the constructor's slots, and body[1] as the body of a
///     private constructor whose mem-initializers move the slots into the
///     members (CODEGEN.md §6). Sema's view of the record is untouched:
///     no member is added, so overload sets, ClassLifecycle and InitCheck
///     never see the C++ machinery.
///
///     Cut here, before every pass that rewrites a body, because the cut is
///     a COUNT of top-level statements (FunctionDecl::ci_split) and those
///     passes insert statements: a temporary SequenceLowering hoists out of
///     the frontier statement lands inside S_pre's block, which is where it
///     runs. Locals S_pre declares stay where they are in the tree; the ones
///     S_post reads are slots (ci_slots), and EmitIR spells both halves'
///     uses of them through the slot, so the block boundary scoping them is
///     never emitted as C++ scope.
///
///   Phase: LOWER, right after FieldInitLowering (statement counts are what
///   CtorInitCheck counted until here).
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
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Statements::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import Location::SourceRange::*;

class CtorInitLowering derives ASTWriter::<CtorInitLowering> {
    pub var sc: *SemaContext;

    fn CtorInitLowering(self, sc: *SemaContext) {
        self.sc  = sc;
        self.ctx = sc->ctx;
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter::<CtorInitLowering>::run(self.sc->tu);
    }

    fn transform_function_decl(self, n: *FunctionDecl) -> vec::<*Decl> {
        var out = ASTWriter::<CtorInitLowering>::transform_function_decl(n);
        self._split(n);
        return out;
    }

    /// body -> { {S_pre} {S_post} }, once (ci_cut): a function reached a
    /// second time is left alone, and so is one whose count no longer fits
    /// (EmitIR ICEs on a split constructor that was never cut).
    priv fn _split(self, n: *FunctionDecl) {
        if (n->ci_split == 0) || n->ci_cut || (n->body_block == &null) || n->is_poisoned() { return; }
        var body = n->body_block;
        var k = static_cast::<usize>(n->ci_split);
        if k > body->body.size() { return; }

        var pre_at  = self._span(body, 0, k);
        var post_at = self._span(body, k, body->body.size());
        var pre  = CompoundStmt::create(self.ctx, pre_at);
        var post = CompoundStmt::create(self.ctx, post_at);
        var pb = self.list_builder::<*Stmt>();
        for var i: usize = 0; i < k; ++i { pb.push(body->body[i]); }
        pb.freeze_into(&(pre->body));
        var qb = self.list_builder::<*Stmt>();
        for var i: usize = k; i < body->body.size(); ++i { qb.push(body->body[i]); }
        qb.freeze_into(&(post->body));

        var b = self.list_builder::<*Stmt>();
        b.push(static_cast::<*Stmt>(pre));
        b.push(static_cast::<*Stmt>(post));
        b.freeze_into(&(body->body));
        n->ci_cut = true;
    }

    /// The source span of statements [from, to), or the body's own when
    /// that is empty (an S_post with nothing after the frontier).
    priv fn _span(self, body: *CompoundStmt, from: usize, to: usize) -> SourceRange {
        if from >= to { return SourceRange::from_bounds(body->range.end.with_offset(-1), u32(1)); }
        return body->body[from]->range | body->body[to - 1]->range;
    }
}
