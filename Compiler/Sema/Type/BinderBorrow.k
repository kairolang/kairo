/// --- The Kairo Project -------------------- Sema/Type/BinderBorrow.k --- ///
///
/// The advice a change to a borrowing binder gets.
///
///   \detail
///     A plain `for` or `case` binder whose type cannot be copied borrows its
///     element in place, read-only (VariableDecl::borrows; control-flow.mdx,
///     Loop binders). It is const to every rule, so each change to it --
///     an assignment, a compound assignment, a call of a method that is not
///     `const`, an `@inout` or `*T` argument, a transfer that would move it
///     away -- is refused where that rule is checked. Those sites call here
///     for the part that is about the binder: why it is read-only and how to
///     get a value that can be changed.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Node::Base::{
    Decl,
    Expr,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    StorageClass,
    VariableDecl,
}
import AST::Node::Expressions::{
    ParenExpr,
    SubscriptExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import Diagnostic::DiagBuilder::DiagBuilder
import Sema::Check::ConformanceChecking::ConformanceChecking
import Sema::SemaContext::SemaContext
import Sema::Type::TypeUtil::TypeUtil
import Token::TokenKind::TokenKind

/// `vd` is a plain binder that borrows: written without `const`, read-only
/// because its type cannot be copied.
pub fn is_borrowing_binder(vd: unsafe *VariableDecl) -> bool {
    return vd != &null && vd->borrows && vd->storage != StorageClass::Const
}

/// The borrowing plain binder a change through `e` reaches: `x`, a field
/// path or an element of it (`x.f`, `x[i]`), its address (`&x`), parens
/// aside. Null for anything else.
pub fn borrowed_binder_of(e: unsafe *Expr) -> unsafe *VariableDecl {
    var unsafe *x = e
    while x != &null {
        if isa<ParenExpr>(x) {
            x = cast<ParenExpr>(x)->inner
            continue
        }

        if isa<ChainExpr>(x) {
            x = cast<ChainExpr>(x)->base
            continue
        }

        if isa<SubscriptExpr>(x) {
            x = cast<SubscriptExpr>(x)->base
            continue
        }

        if isa<UnaryOperatorExpr>(x)
            && cast<UnaryOperatorExpr>(x)->op_token.kind == TokenKind::OpAmp {
            x = cast<UnaryOperatorExpr>(x)->operand
            continue
        }

        break
    }

    if x == &null || !isa<NamedIdentExpr>(x) {
        return &null
    }

    var unsafe *vd = dyn_cast<VariableDecl>(
        cast<NamedIdentExpr>(x)->resolved_decl,
    )

    return if (is_borrowing_binder(vd)) => (vd) else => &null
}

/// The notes for a change to `vd`, a borrowing binder: where it is bound,
/// why it is read-only, and the two ways to a value that can be changed.
pub fn note_borrowed_binder(sc: unsafe *SemaContext, b: *DiagBuilder, vd: unsafe *VariableDecl) {
    var        tu  = TypeUtil(sc)
    var        nm  = sc->ctx->get_spelling(vd->name)
    var unsafe *c  = tu.as_value(vd->type_)
    var        ts  = if (c != &null) => (tu.str(c)) else => "its type"
    var        how = f"bind '*{nm}' in a 'for' to change the element in place"
    if c != &null && !c->is_dependent() && ConformanceChecking(sc).copy_method(c) != &null {
        how = f"bind a local to change a copy, 'var mine = {nm}.copy()', or {how}"
    }

    b->note(
        vd->name.range.start,
        f"the binder '{nm}' borrows its element in place, read-only, because '{ts}' cannot be copied; {how}",
    )->child_first(vd->name.range)
}
