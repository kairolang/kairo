/// --- The Kairo Project --------------------- Sema/Type/NullnessFlow.k --- ///
///
///   \brief What a null test is: the one classifier every spelling of it
///          goes through (Compiler/Sema/NULLABLE.md §5).
///
///   \detail
///     `x?` is the null test; every other spelling desugars to it (2.1, 2.2):
///
///       x?            present     x != null     present     null != x   present
///       !x?           absent      x == null     absent      null == x   absent
///
///     looking through parentheses, and through `!` / `not` at any depth
///     (each flips the polarity: `!(x == null)` is `x?`). `null_test_of`
///     is the ONLY place that knows these spellings. NullTestLowering lowers
///     through it, and the flow analysis that lands here later (G11: the
///     nullness environment ExprTyper reports into) narrows through it, so
///     the spellings cannot lower or narrow differently. A new spelling
///     (the `x?` inside a desugared `??` / `?.` / `unwrap!()`) is added here
///     and nowhere else.
///
///     It classifies TYPED trees. A test is one only when its operand's
///     type is nullable: a user `op ?` on a record (resolved_op set) is that
///     record's operator, not a null test, and `p == &null` on an `unsafe
///     *T` is a pointer comparison. (A plain `null` against a non-nullable
///     never reaches a typed tree: OperatorTyping rejects it.)
///
///   Phase: TYPE (classifier only, today); called by LOWER.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Expressions::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import Token::Token::*;
import Token::TokenKind::*;

/// One classified null test. `operand` is the nullable tested, null when
/// the expression is no null test. `present` is the polarity: true when the
/// expression is true exactly when `operand` holds a value (`x?`,
/// `x != null`), false when it is true exactly when it is null (`!x?`,
/// `x == null`).
struct NullTest {
    var operand: *Expr = &null;
    var present: bool  = true;
}

/// \p e without the parentheses around it.
fn null_flow_strip_parens(e: *Expr) -> *Expr {
    var x = e;
    while (x != &null) && isa::<ParenExpr>(x) { x = cast::<ParenExpr>(x)->inner; }
    return x;
}

/// \p e is the `null` (or `&null`) literal, through parentheses: that
/// literal, else null. Untyped on purpose: OperatorTyping asks before it
/// types the operands, so a `null` against a non-nullable gets the null
/// comparison's error, not the literal's "cannot infer".
fn null_literal_of(e: *Expr) -> *NullLiteralExpr {
    var x = null_flow_strip_parens(e);
    if (x == &null) || (!isa::<NullLiteralExpr>(x)) { return &null; }
    return cast::<NullLiteralExpr>(x);
}

/// \p e has a nullable type, read as a value (a C++ `T?&` is its `T?`).
fn null_flow_is_nullable(e: *Expr) -> bool {
    if (e == &null) || (e->type_ == &null) { return false; }
    var t = e->type_;
    if isa::<CXXLValueRefType>(t)      { t = cast::<CXXLValueRefType>(t)->referee; }
    else if isa::<CXXRValueRefType>(t) { t = cast::<CXXRValueRefType>(t)->referee; }
    var c = canon_unqual(t);
    return (c != &null) && isa::<NullableType>(c);
}

/// The null test \p e is, or one with no operand. See the file header for
/// the spellings.
fn null_test_of(e: *Expr) -> NullTest {
    var out = NullTest{};
    var x = null_flow_strip_parens(e);
    if x == &null { return out; }

    if isa::<UnaryOperatorExpr>(x) {
        var u = cast::<UnaryOperatorExpr>(x);
        if u->resolved_op != &null { return out; }   // a user operator, never the test.
        var k = u->op_token.kind;
        if u->is_postfix() && (k == TokenKind::OpQuestion) {
            if !null_flow_is_nullable(u->operand) { return out; }
            out.operand = u->operand;
            out.present = true;
            return out;
        }
        if u->is_prefix() && ((k == TokenKind::OpExclaim) || (k == TokenKind::KwNot)) {
            var inner = null_test_of(u->operand);
            if inner.operand != &null { inner.present = !inner.present; }
            return inner;
        }
        return out;
    }

    if isa::<BinaryOperatorExpr>(x) {
        var b = cast::<BinaryOperatorExpr>(x);
        if b->resolved_op != &null { return out; }
        var k = b->op_token.kind;
        if (k != TokenKind::OpEqualEqual) && (k != TokenKind::OpExclaimEqual) { return out; }
        var ln = null_literal_of(b->lhs);
        var rn = null_literal_of(b->rhs);
        if (ln != &null) == (rn != &null) { return out; }   // neither, or `null == null`.
        var other = (b->rhs) if (ln != &null) else (b->lhs);
        if !null_flow_is_nullable(other) { return out; }    // `p == &null` on a raw pointer.
        out.operand = other;
        out.present = k == TokenKind::OpExclaimEqual;
        return out;
    }
    return out;
}
