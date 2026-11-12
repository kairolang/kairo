/// --- The Kairo Project ----------------- Sema/Lower/ExprBodyDesugar.k --- ///
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
///   A closure's expression body is the same rewrite (`fn (x: i32) = x * 2`
///   -> `{ return x * 2 }`). There the choice reads the RESOLVED return
///   type: a closure's is inferred when omitted (ControlTyping::
///   type_closure writes it back into `return_type`), and EmitIR spells
///   the lambda's `-> R` from it, so `void` and `!` take `e;` and anything
///   else `return e`.
///
///   Phase: LOWER, first of the passes that rewrite statements (only
///   VariantInitLowering, which replaces construction nodes in place, and
///   EnumLayoutLowering, which touches no body, run before it). Every later
///   lowering then sees an ordinary block, which SequenceLowering needs -- it
///   hoists arguments into statements, and an expression body has no
///   statement position to hoist into.
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

import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Declarations::{
    FnBodyKind,
    FunctionDecl,
}
import AST::Node::Expressions::ClosureExpr
import AST::Node::Statements::{
    CompoundStmt,
    ExpressionStmt,
    ReturnStmt,
}
import AST::Visitor::ASTWriter::ASTWriter
import Sema::Lower::LowerStep::LowerStep
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}

pub class ExprBodyDesugar derives ASTWriter<ExprBodyDesugar> {
    pub var sc: *SemaContext

    fn ExprBodyDesugar(self, sc: *SemaContext) {
        self.sc  = sc
        self.ctx = sc->ctx
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        self.sc->begin_lower(LowerStep::ExprBody)
        if self.sc->tu == &null {
            return
        }

        ASTWriter<ExprBodyDesugar>::run(self, self.sc->tu)
    }

    fn transform_function_decl(self, n: unsafe *FunctionDecl) -> cxx::std::vector<unsafe *Decl> {
        var out = ASTWriter<ExprBodyDesugar>::transform_function_decl(self, n)
        if n->body_kind != FnBodyKind::Expr || n->body_expr == &null {
            return out
        }

        var unsafe *e              = n->body_expr
        var        s: unsafe *Stmt = &null
        if n->is_noreturn || n->return_type == &null {
            s = ExpressionStmt::create(self.ctx, e->range, e)
        } else {
            s = ReturnStmt::create(self.ctx, e->range, e)
        }

        var stmts = self.list_builder<unsafe *Stmt>()
        stmts.push(s)
        var unsafe *body = CompoundStmt::create(self.ctx, e->range)
        stmts.freeze_into(&body->body)

        n->body_block = body
        n->body_expr  = &null
        n->body_kind  = FnBodyKind::Block
        return out
    }

    fn transform_closure_expr(self, n: unsafe *ClosureExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<ExprBodyDesugar>::transform_closure_expr(self, n)
        if n->body_expr == &null {
            return out
        }

        var unsafe *e              = n->body_expr
        var        s: unsafe *Stmt = &null
        if n->is_noreturn || self._is_void(n->return_type) {
            s = ExpressionStmt::create(self.ctx, e->range, e)
        } else {
            s = ReturnStmt::create(self.ctx, e->range, e)
        }

        var stmts = self.list_builder<unsafe *Stmt>()
        stmts.push(s)
        var unsafe *body = CompoundStmt::create(self.ctx, e->range)
        stmts.freeze_into(&body->body)

        n->body_block = body
        n->body_expr  = &null
        n->body_kind  = FnBodyKind::Block
        return out
    }

    /// No return type at all, or one that is `void` / `!`.
    priv fn _is_void(self, t: unsafe *Type) -> bool {
        if t == &null || t->canonical == &null {
            return true
        }

        var unsafe *c = canon_unqual(t->canonical)
        if c == &null || !isa<BuiltinType>(c) {
            return false
        }

        var k = cast<BuiltinType>(c)->builtin
        return k == BuiltinKind::Void || k == BuiltinKind::Never
    }
}
