/// --- The Kairo Project ---------------- Sema/Lower/ExprBodyDesugar.k --- ///
///
///   \brief An expression-bodied function becomes the block it abbreviates.
///
///   \detail
///       fn dot(const self, o: Vec2) -> i32 = self.x * o.x    ->  { return self.x * o.x }
///       fn bump(@inout n: i32) = n += 1                       ->  { n += 1 }
///       fn fail() -> ! = panic!("x")                         ->  { panic!("x") }
///
///     Syntax only: nothing is typed, looked up or minted. The choice of
///     `return e` or `e;` reads the WRITTEN signature -- a return type, and
///     not `!` -- because that is the same fact EmitIR spells the return
///     type from: no written type emits `void`, so the body must not return
///     a value there. `return e` in a void function would also be legal C++
///     for a void `e`, but not for a non-void one, and an inferred return
///     type is not spelled yet.
///
///     The expression node moves into the new statement unchanged, typed
///     and bound as Sema left it; only its container changes.
///
///   \par Postcondition
///     No FunctionDecl with `body_kind == Expr` reaches codegen. EmitIR's
///     `_unsupported_body` ICEs on one, naming this pass.
///
///   Closures keep their expression bodies: EmitIR has no closure path yet,
///   and the day it does, it is this same rewrite on ClosureExpr.
///
///   Phase: LOWER, FIRST. Every later lowering then sees an ordinary block,
///   which SequenceLowering needs -- it hoists arguments into statements, and
///   an expression body has no statement position to hoist into.
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
import AST::Node::Declarations::*;
import AST::Node::Casting::*;

__inline_cpp("
#define ASTWriter_ExprBodyDesugar ASTWriter<ExprBodyDesugar>
");

class ExprBodyDesugar derives ASTWriter::<ExprBodyDesugar> {
    pub var sc: *SemaContext;

    fn ExprBodyDesugar(self, sc: *SemaContext) {
        self.sc  = sc;
        self.ctx = sc->ctx;
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter_ExprBodyDesugar::run(self.sc->tu);
    }

    fn transform_function_decl(self, n: *FunctionDecl) -> vec::<*Decl> {
        var out = ASTWriter_ExprBodyDesugar::transform_function_decl(n);
        if (n->body_kind != FnBodyKind::Expr) || (n->body_expr == &null) { return out; }

        var e = n->body_expr;
        var s: *Stmt = &null;
        if n->is_noreturn || (n->return_type == &null) {
            s = static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, e->range, e));
        } else {
            s = static_cast::<*Stmt>(ReturnStmt::create(self.ctx, e->range, e));
        }

        var stmts = self.list_builder::<*Stmt>();
        stmts.push(s);
        var body = CompoundStmt::create(self.ctx, e->range);
        stmts.freeze_into(&(body->body));

        n->body_block = body;
        n->body_expr  = &null;
        n->body_kind  = FnBodyKind::Block;
        return out;
    }
}
