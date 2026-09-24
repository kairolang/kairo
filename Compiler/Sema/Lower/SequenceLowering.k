/// --- The Kairo Project ---------------- Sema/Lower/SequenceLowering.k --- ///
///
///   \brief Make argument evaluation order explicit.
///
///   \detail
///     Kairo evaluates a call's arguments left to right. C++ does not promise
///     any order between them, and clang and gcc disagree in practice
///     (`f(g(), g())` is 1020 on one and 2010 on the other). Nothing is asked
///     of clang: the order is written into the tree.
///
///       f(g(), x, h())
///     ->
///       ({ T0 __kairo_arg0 = g(); T2 __kairo_arg1 = h(); f(__kairo_arg0, x, __kairo_arg1); })
///
///     A statement expression, not hoisted statements: it sits where the call
///     sat, so `c && f(g(), h())` still short-circuits and a call in a loop
///     header still runs per iteration. Its block is also the scope of every
///     temporary an argument needs, which is what lets a slice literal be
///     hoisted at all (see _mark_extended).
///
///     Only arguments with side effects are bound; a name, a literal, a field
///     path, `&x` stay in place. A call with fewer than two such arguments is
///     never rewritten -- there is nothing to order -- so almost every call is
///     untouched. The receiver of a member call counts as argument zero.
///
///   \par Not rewritten
///     A call whose result is an lvalue (an imported `T&` return) or a record
///     value: a statement expression yields a prvalue, which would change the
///     category or force a copy the type may not have. Those calls keep C++'s
///     order. Primitive operators (`a + b` with two impure operands) are not
///     calls and are not covered here.
///
///   Phase: LOWER, after OperatorLowering (user operators are calls by then)
///   and before ListLiteralLowering (a hoisted slice literal is marked
///   Extended here and given its backing there).
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
import AST::LangItems::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Node::CanonicalNodes::*;
import AST::Kind::ExprKind::*;
import AST::Kind::TypeKind::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;

__inline_cpp("
#define ASTWriter_SequenceLowering ASTWriter<SequenceLowering>
");

class SequenceLowering derives ASTWriter::<SequenceLowering> {
    pub var sc: *SemaContext;
    priv var tu: TypeUtil;
    priv var synth: LowerSynth;

    fn SequenceLowering(self, sc: *SemaContext) {
        self.sc  = sc;
        self.ctx = sc->ctx;
        self.tu  = TypeUtil(sc);
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter_SequenceLowering::run(self.sc->tu);
    }

    // --- the rewrite ----------------------------------------------------------

    fn transform_call_expr(self, n: *CallExpr) -> *Expr {
        // Children first: an inner call `f(g(h(), k()))` is sequenced on its
        // own, and this call then sees it as one impure argument.
        var out = ASTWriter_SequenceLowering::transform_call_expr(n);
        if n->is_poisoned() || n->is_instantiation_dependent() { return out; }
        if !self._result_sequenceable(n) { return out; }

        // The receiver of `x.m(...)` is operand zero.
        var recv: *ChainExpr = &null;
        if (n->callee != &null) && isa::<ChainExpr>(n->callee) {
            var ch = cast::<ChainExpr>(n->callee);
            if (ch->base != &null) && (ch->steps.size() > 0)
            && (ch->steps.get(0)->access_kind != ChainExpr::AccessKind::ColonColon) { recv = ch; }
        }

        var impure: usize = 0;
        if (recv != &null) && (!LowerSynth::pure(recv->base)) { impure += 1; }
        for var i: usize = 0; i < n->args.size(); ++i {
            if !LowerSynth::pure(n->args[i]) { impure += 1; }
        }
        if impure < 2 { return out; }

        // Every impure operand must have a type to declare a local with.
        if (recv != &null) && (!LowerSynth::pure(recv->base)) && (recv->base->type_ == &null) { return out; }
        for var i: usize = 0; i < n->args.size(); ++i {
            if (!LowerSynth::pure(n->args[i])) && (n->args[i]->type_ == &null) { return out; }
        }

        var stmts = self.list_builder::<*Stmt>();
        if (recv != &null) && (!LowerSynth::pure(recv->base)) {
            recv->base = self._bind(recv->base, &stmts);
        }
        var args = self.list_builder::<*Expr>();
        for var i: usize = 0; i < n->args.size(); ++i {
            var a = n->args[i];
            args.push((a) if (LowerSynth::pure(a)) else (self._bind(a, &stmts)));
        }
        args.freeze_into(&(n->args));                 // same indices: arg_map is untouched.

        stmts.push(static_cast::<*Stmt>(ExpressionStmt::create(self.ctx, n->range, static_cast::<*Expr>(n))));
        var body = CompoundStmt::create(self.ctx, n->range);
        stmts.freeze_into(&(body->body));

        var se = StmtExpr::create(self.ctx, n->range, body);
        se->type_          = n->type_;
        se->value_category = Expr::ValueCategory::RValue;
        se->expr_flags     = n->expr_flags;
        return static_cast::<*Expr>(se);
    }

    /// A statement expression is a prvalue of its last statement's type. A
    /// call that yields an lvalue, or a record (the copy out of the block may
    /// not exist), keeps C++'s order rather than a changed meaning.
    priv fn _result_sequenceable(self, n: *CallExpr) -> bool {
        if n->value_category == Expr::ValueCategory::LValue { return false; }
        var t = n->type_;
        if t == &null { return true; }                  // void-typed calls have no slot to read.
        if isa::<CXXLValueRefType>(t) || isa::<CXXRValueRefType>(t) { return false; }
        var c = canon_unqual(t);
        if (c != &null) && (c->kind == TypeKind::RecordType) { return false; }
        return true;
    }

    /// `T __kairo_argK = e;` into \p stmts; returns the name that reads it.
    priv fn _bind(self, e: *Expr, stmts: *ListBuilder::<*Stmt>) -> *Expr {
        var t = e->type_;
        var vd = self.synth.local(e->range, "arg", t, e);
        self._mark_extended(e);                         // a slice literal's backing lives in this block.
        stmts->push(static_cast::<*Stmt>(DeclStmt::create(self.ctx, e->range, static_cast::<*Decl>(vd))));
        return self.synth.use_of(vd, e->range, Expr::ValueCategory::LValue);
    }

    /// Mirrors LiteralTyping::mark_list_storage: the local this literal now
    /// initializes is a `var`, so its backing array extends to the block.
    priv fn _mark_extended(self, e_in: *Expr) {
        var e = self.tu.strip_parens(e_in);
        if (e == &null) || (!isa::<ListLiteralExpr>(e)) { return; }
        var n = cast::<ListLiteralExpr>(e);
        if (n->type_ == &null) || (!self.tu.is_slice(n->type_)) { return; }
        n->storage = ListStorage::Extended;
        for var i: usize = 0; i < n->elements.size(); ++i { self._mark_extended(n->elements[i]); }
    }
}

__inline_cpp("
#undef ASTWriter_SequenceLowering
");