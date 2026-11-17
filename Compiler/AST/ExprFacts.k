/// --- The Kairo Project ------------------------------ AST/ExprFacts.k --- ///
///
/// Reading an expression's shape: the expression inside its
/// parentheses, and the declaration a call names.
///
///   \detail
///     A call's callee is a name (`f(x)`) or a chain whose last step is the
///     function (`a::f(x)`, `o.f(x)`), each possibly parenthesized; anything
///     else is a call through a value and names no declaration. The passes
///     that ask "what does this call name" differ in which of the call's
///     other slots they also read, so those are options (CalleeOpt) on one
///     reader.
///
///   Layer: AST. Imports AST only.
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
import AST::Node::Declarations::FunctionDecl
import AST::Node::Expressions::{
    AssignOperatorExpr,
    CallExpr,
    ParenExpr,
    SubscriptExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::OperatorFacts::OperatorFacts
import Support::FlagSet::{
    FlagBit,
    FlagSet,
}
import Token::TokenKind::TokenKind

/// `e` without the parentheses around it, however many; null for null.
pub fn strip_parens(e: unsafe *Expr) -> unsafe *Expr {
    var unsafe *x = e
    while x != &null && isa<ParenExpr>(x) {
        x = cast<ParenExpr>(x)->inner
    }

    return x
}

/// The slots callee_decl reads besides the callee's own resolved_decl.
/// With none set the answer is what the callee expression is bound to.
/// The subscript on the left of the plain `=` `asn` that Sema resolved to
/// the setter form of `op []=` (OperatorFacts::is_subscript_setter), or
/// null. The assignment is then one call of that setter, with the
/// subscript's index and the assignment's right side as its arguments.
pub fn setter_store_target(asn: unsafe *AssignOperatorExpr) -> unsafe *SubscriptExpr {
    if asn == &null || asn->op_token.kind != TokenKind::OpEqual || asn->lhs == &null {
        return &null
    }

    var unsafe *s = dyn_cast<SubscriptExpr>(strip_parens(asn->lhs))
    if s == &null || s->resolved_op == &null {
        return &null
    }

    var unsafe *f = dyn_cast<FunctionDecl>(s->resolved_op)
    if f == &null || !OperatorFacts::is_subscript_setter(f) {
        return &null
    }

    return s
}

pub enum CalleeOpt derives u8 {
    /// A construction: `ctor_decl`, when it is a function, is the callee.
    /// One that is not a function (a record built with no constructor) is
    /// passed over and the callee expression answers.
    CtorDecl = 1 << 0,

    /// A call of a value through its `op ()`: `functor_op` is the callee.
    /// Read after `ctor_decl`.
    FunctorOp = 1 << 1,

    /// A bare name not yet bound whose overload cell holds exactly one
    /// declaration names that declaration.
    CandidateCell = 1 << 2,

    /// A chain's last step with no resolved_decl answers with its name
    /// node's resolved_decl.
    StepName = 1 << 3,
}

/// CalleeOpt's variants are its FlagSet's bits (Support/FlagSet.k).
extend CalleeOpt impl FlagBit<u8> {
    inline fn bit(const self) -> u8 {
        return self as u8
    }
}

/// The declaration the callee expression `callee` names: through
/// parentheses, a name's resolved_decl or a chain's last step's. Null for
/// null, for an unbound name, and for a callee that is neither (a call
/// through a value). Of `opts` only CandidateCell and StepName apply.
pub fn callee_expr_decl(callee: unsafe *Expr,
                        opts:   FlagSet<CalleeOpt, u8> = FlagSet<CalleeOpt, u8>()) -> unsafe *Decl {
    var unsafe *c = strip_parens(callee)
    if c == &null {
        return &null
    }

    if isa<NamedIdentExpr>(c) {
        var unsafe *ni = cast<NamedIdentExpr>(c)
        if ni->resolved_decl == &null
            && opts.has(CalleeOpt::CandidateCell)
            && ni->candidate_cell != &null
            && ni->candidate_cell->size() == 1 {
            return ni->candidate_cell->get(0)
        }

        return ni->resolved_decl
    }

    if isa<ChainExpr>(c) {
        var unsafe *ch = cast<ChainExpr>(c)
        if ch->steps.size() == 0 {
            return &null
        }

        var unsafe *last = ch->steps.get(ch->steps.size() - 1)
        if last->resolved_decl == &null && opts.has(CalleeOpt::StepName) && last->name != &null {
            return last->name->resolved_decl
        }

        return last->resolved_decl
    }

    return &null
}

/// The declaration `call` calls: the slots `opts` selects, in CalleeOpt's
/// order, then callee_expr_decl of its callee. Null for a null call. The
/// result is a function, or whatever else the callee is bound to (a
/// record, for a construction read without CtorDecl); a caller that wants
/// a function casts.
pub fn callee_decl(call: unsafe *CallExpr,
                   opts: FlagSet<CalleeOpt, u8> = FlagSet<CalleeOpt, u8>()) -> unsafe *Decl {
    if call == &null {
        return &null
    }

    if opts.has(CalleeOpt::CtorDecl)
        && call->ctor_decl != &null
        && isa<FunctionDecl>(call->ctor_decl) {
        return call->ctor_decl
    }

    if opts.has(CalleeOpt::FunctorOp) && call->functor_op != &null {
        return call->functor_op
    }

    return callee_expr_decl(call->callee, opts)
}
