/// --- The Kairo Project ---------------------- Sema/Lower/LowerSynth.k --- ///
///
///   \brief What every lowering mints: identifier tokens interned into THIS
///          file's table, integer literals with a fresh Immediate::IntData
///          slot, fresh `__kairo_` locals and the names that read them, and
///          the purity test SequenceLowering orders arguments by.
///
///   One copy. Three passes each carried their own `_ident_token`, and the
///   `Token` invariant (16 bytes, an imm index into the owning file's table,
///   RESOLUTION.md hard invariant #2) is the kind of rule that drifts when it
///   is written in three places.
///
///   Held by value on each pass, so counters are per pass; passes use
///   different name hints (`arg`, `tmp`, `lhs`, `sum`) and never collide.
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
import AST::LangItems::*;
import AST::Node::Base::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::ExprKind::*;
import Lexer::Immediate::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;

class LowerSynth {
    pub var sc: *SemaContext;
    priv var _counter: u32 = 0;

    fn LowerSynth(self) { self.sc = &null; }
    fn LowerSynth(self, sc: *SemaContext) { self.sc = sc; }

    /// An identifier token for a name this pass invented.
    fn ident(self, range: SourceRange, spelling: string) -> Token {
        var t = Token();
        t.kind  = TokenKind::LitIdentifier;
        t.range = range;
        t.imm   = self.sc->imm_table()->intern_ident_copy(spelling);
        return t;
    }

    /// `__kairo_<hint>K`, unique within this pass.
    fn fresh(self, range: SourceRange, hint: string) -> Token {
        var t = self.ident(range, LowerTargets::reserved_prefix() + hint + f"{self._counter}");
        self._counter += 1;
        return t;
    }

    /// A punctuator token with no source bytes behind it (the `=` of a minted
    /// assignment). TokenSink creates it from the kind alone.
    fn punct(self, range: SourceRange, kind: TokenKind) -> Token {
        var t = Token();
        t.kind  = kind;
        t.range = range;
        return t;
    }

    /// An integer literal typed \p kind, its IntData slot minted and written
    /// straight in: no source text, so EmitIR spells it from the value.
    fn int_literal(self, range: SourceRange, value: u64, kind: BuiltinKind) -> *Expr {
        var tbl = self.sc->imm_table();
        var idx = tbl->create::<Immediate::IntData>();
        var d   = tbl->get::<Immediate::IntData>(idx);
        d->value_lo = value;
        d->value_hi = 0;
        d->bits     = 0;
        d->base     = 10;
        d->flags    = 0;

        var t = Token();
        t.kind  = TokenKind::LitInt;
        t.range = range;
        t.imm   = idx;

        var lit = IntegerLiteralExpr::create(self.sc->ctx, range, t);
        lit->type_          = self.sc->builtin(kind);
        lit->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(lit);
    }

    /// `var __kairo_<hint>K: <ty> = <init>`. The caller wraps it in a DeclStmt
    /// and places it; the decl is the identity every use_of() binds to.
    fn local(self, range: SourceRange, hint: string, ty: *Type, init: *Expr) -> *VariableDecl {
        var vd    = VariableDecl::create(self.sc->ctx, range, self.fresh(range, hint), StorageClass::Var);
        vd->type_ = ty;
        vd->init  = init;
        return vd;
    }

    /// A read of a local this pass minted. One node per use: a node has one
    /// parent, and two parents sharing one is a rewrite waiting to happen.
    fn use_of(self, vd: *VariableDecl, range: SourceRange, cat: Expr::ValueCategory) -> *Expr {
        var use = NamedIdentExpr::create(self.sc->ctx, range, vd->name);
        use->resolved_decl  = static_cast::<*Decl>(vd);
        use->type_          = vd->type_;
        use->value_category = cat;
        return static_cast::<*Expr>(use);
    }

    /// No side effect and no dependence on one: reading \p e before or after
    /// another operand changes nothing. Conservative: anything not listed is
    /// impure. SequenceLowering orders by it; OperatorLowering decides by it
    /// whether a compound assignment's left side is bound once first.
    static fn pure(e: *Expr) -> bool {
        if e == &null { return true; }
        switch e->kind {
            case ExprKind::IntegerLiteralExpr   { return true; }
            case ExprKind::FloatingLiteralExpr  { return true; }
            case ExprKind::CharacterLiteralExpr { return true; }
            case ExprKind::BooleanLiteralExpr   { return true; }
            case ExprKind::NullLiteralExpr      { return true; }
            case ExprKind::StringLiteralExpr    { return !cast::<StringLiteralExpr>(e)->is_format(); }
            case ExprKind::NamedIdentExpr       { return true; }
            case ExprKind::SizeOfExpr           { return true; }
            case ExprKind::AlignOfExpr          { return true; }
            case ExprKind::ParenExpr            { return LowerSynth::pure(cast::<ParenExpr>(e)->inner); }
            case ExprKind::UnsafeExpr           { return LowerSynth::pure(cast::<UnsafeExpr>(e)->operand); }
            case ExprKind::ImplicitBoundaryCastExpr { return LowerSynth::pure(cast::<ImplicitBoundaryCastExpr>(e)->original); }
            case ExprKind::ChainExpr {
                // A field path off a pure base. An operator step is a call
                // (only as a callee, which never reaches here as an operand).
                var c = cast::<ChainExpr>(e);
                for var i: usize = 0; i < c->steps.size(); ++i {
                    var st = c->steps.get(i);
                    if st->is_operator() { return false; }
                    if (st->access_kind == ChainExpr::AccessKind::QuestionDot)
                    || (st->access_kind == ChainExpr::AccessKind::QuestionArrow) { return false; }
                }
                return LowerSynth::pure(c->base);
            }
            case ExprKind::UnaryOperatorExpr {
                var u = cast::<UnaryOperatorExpr>(e);
                if u->resolved_op != &null { return false; }
                var k = u->op_token.kind;
                if (k == TokenKind::OpPlusPlus) || (k == TokenKind::OpMinusMinus) { return false; }
                return LowerSynth::pure(u->operand);
            }
            case ExprKind::BinaryOperatorExpr {
                var b = cast::<BinaryOperatorExpr>(e);
                if b->resolved_op != &null { return false; }
                return LowerSynth::pure(b->lhs) && LowerSynth::pure(b->rhs);
            }
            case ExprKind::SubscriptExpr {
                var s = cast::<SubscriptExpr>(e);
                if s->resolved_op != &null { return false; }
                return LowerSynth::pure(s->base) && LowerSynth::pure(s->index);
            }
            case ExprKind::TypeCastExpr {
                var c = cast::<TypeCastExpr>(e);
                if (c->resolved_op != &null) || (c->resolved_ctor != &null) { return false; }
                return LowerSynth::pure(c->operand);
            }
            case ExprKind::ListLiteralExpr {
                var l = cast::<ListLiteralExpr>(e);
                for var i: usize = 0; i < l->elements.size(); ++i { if !LowerSynth::pure(l->elements[i]) { return false; } }
                return true;
            }
            default { return false; }   // calls, assignment, if-expr, closures, ...
        }
    }
}