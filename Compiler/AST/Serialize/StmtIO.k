/// --- The Kairo Project ----------------------- AST/Serialize/StmtIO.k --- ///
///
///   The Stmt family: one `io_` function per statement class, the structs
///   statements hold by value (Binding, CatchArm, MatchCase, DispatchCase),
///   and the entry points the archive's hooks call (stmt_alloc, stmt_io).
///
///   The rule for a field is DeclIO.k's: stored through a primitive when the
///   parser writes it, named in the DEBUG block when a later stage does.
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

import AST::ASTSupport::FrozenList
import AST::Kind::StmtKind::StmtKind
import AST::Node::Base::{
    Decl,
    Expr,
    Pattern,
    Stmt,
    Type,
}
import AST::Node::Declarations::VariableDecl
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Statements
import AST::Serialize::Archive::ASTArchive
import AST::Serialize::NodeCommon::io_annotations

fn <T: type> new_stmt(ar: unsafe *ASTArchive) -> unsafe *Stmt {
    var unsafe *n = ar->ctx->alloc<T>()
    n->init_annotations(unsafe &ar->ctx->ast_alloc)
    return unsafe (n as unsafe *Stmt)
}

/// Reads a statement's kind and allocates an object of its class.
pub fn stmt_alloc(ar: unsafe *ASTArchive) -> unsafe *Stmt {
    var kind = StmtKind::RecoveryStmt
    ar->en<StmtKind>(&kind)
    var cls = kind
    if kind == StmtKind::RecoveryStmt {
        ar->en<StmtKind>(&cls)
    }

    var s: unsafe *Stmt = &null
    match cls {
        case StmtKind::CompoundStmt {
            s = new_stmt<Statements::CompoundStmt>(ar)
        } case StmtKind::ExpressionStmt {
            s = new_stmt<Statements::ExpressionStmt>(ar)
        } case StmtKind::DeclStmt {
            s = new_stmt<Statements::DeclStmt>(ar)
        } case StmtKind::ReturnStmt {
            s = new_stmt<Statements::ReturnStmt>(ar)
        } case StmtKind::BreakStmt {
            s = new_stmt<Statements::BreakStmt>(ar)
        } case StmtKind::ContinueStmt {
            s = new_stmt<Statements::ContinueStmt>(ar)
        } case StmtKind::PanicStmt {
            s = new_stmt<Statements::PanicStmt>(ar)
        } case StmtKind::YieldStmt {
            s = new_stmt<Statements::YieldStmt>(ar)
        } case StmtKind::RuntimeAssertStmt {
            s = new_stmt<Statements::RuntimeAssertStmt>(ar)
        } case StmtKind::StaticAssertStmt {
            s = new_stmt<Statements::StaticAssertStmt>(ar)
        } case StmtKind::LabelIntrinsicStmt {
            s = new_stmt<Statements::LabelIntrinsicStmt>(ar)
        } case StmtKind::JumpIntrinsicStmt {
            s = new_stmt<Statements::JumpIntrinsicStmt>(ar)
        } case StmtKind::ConditionalStmt {
            s = new_stmt<Statements::ConditionalStmt>(ar)
        } case StmtKind::WhileLoopStmt {
            s = new_stmt<Statements::WhileLoopStmt>(ar)
        } case StmtKind::LoopStmt {
            s = new_stmt<Statements::LoopStmt>(ar)
        } case StmtKind::RangedForStmt {
            s = new_stmt<Statements::RangedForStmt>(ar)
        } case StmtKind::IndexedForStmt {
            s = new_stmt<Statements::IndexedForStmt>(ar)
        } case StmtKind::MatchStmt {
            s = new_stmt<Statements::MatchStmt>(ar)
        } case StmtKind::LabeledStmt {
            s = new_stmt<Statements::LabeledStmt>(ar)
        } case StmtKind::TryCatchStmt {
            s = new_stmt<Statements::TryCatchStmt>(ar)
        } case StmtKind::FinallyStmt {
            s = new_stmt<Statements::FinallyStmt>(ar)
        } case StmtKind::UnsafeBlockStmt {
            s = new_stmt<Statements::UnsafeBlockStmt>(ar)
        } case StmtKind::ContextBindingStmt {
            s = new_stmt<Statements::ContextBindingStmt>(ar)
        } case StmtKind::DestructuringDeclStmt {
            s = new_stmt<Statements::DestructuringDeclStmt>(ar)
        } case StmtKind::InlineBlockStmt {
            s = new_stmt<Statements::InlineBlockStmt>(ar)
        } case StmtKind::EvalBlockStmt {
            s = new_stmt<Statements::EvalBlockStmt>(ar)
        } case StmtKind::SwitchDispatchStmt {
            s = new_stmt<Statements::SwitchDispatchStmt>(ar)
        } default {
            return &null
        }
    }

    s->kind = kind
    if kind == StmtKind::RecoveryStmt {
        s->recovery_kind = cls
    }

    return s
}

fn io_stmt_base(ar: unsafe *ASTArchive, s: unsafe *Stmt) {
    if !ar->reading() {
        ar->en<StmtKind>(&s->kind)
        if s->kind == StmtKind::RecoveryStmt {
            ar->en<StmtKind>(&s->recovery_kind)
        }
    }

    ar->range(&s->range)
    io_annotations<Stmt>(ar, s)
    eval if defined!(DEBUG) {
        if s->kind != StmtKind::RecoveryStmt {
            ar->sema_is(s->recovery_kind == StmtKind::RecoveryStmt, "Stmt::recovery_kind")
        }
    }
}

//  structs held by value

/// The bindings of a ranged `for`, a context binding or a destructuring
/// declaration. `decl` is the parser's: the variable each name declares.
pub fn io_bindings(ar: unsafe *ASTArchive, @inout l: FrozenList<Statements::Binding>) {
    var n = ar->list<Statements::Binding>(&l)
    for var i: usize = 0; i < n; ++i {
        var unsafe *b = l.get(i)
        ar->expr<NamedIdentExpr>(&b->name)
        ar->flag(&b->is_const)
        ar->flag(&b->is_explicit)
        ar->flag(&b->is_discard)
        ar->num8(&b->shorthand.bits)
        ar->type_<Type>(&b->type_)
        ar->range(&b->range)
        ar->decl<VariableDecl>(&b->decl)
    }
}

/// Match arms: shared with MatchExpr, which holds the same list.
pub fn io_match_cases(ar: unsafe *ASTArchive, @inout l: FrozenList<Statements::MatchCase>) {
    var n = ar->list<Statements::MatchCase>(&l)
    for var i: usize = 0; i < n; ++i {
        var unsafe *c = l.get(i)
        ar->pattern_list<Pattern>(&c->patterns)
        ar->expr<Expr>(&c->guard)
        ar->stmt<Statements::CompoundStmt>(&c->body)
        ar->expr<Expr>(&c->expression)
        ar->range(&c->range)
        ar->flag(&c->is_default)
    }
}

//  the classes

fn io_compound_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::CompoundStmt) {
    ar->stmt_list<Stmt>(&n->body)
}

fn io_expression_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::ExpressionStmt) {
    ar->expr<Expr>(&n->expr)
}

fn io_decl_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::DeclStmt) {
    ar->decl<Decl>(&n->decl)
}

fn io_return_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::ReturnStmt) {
    ar->expr<Expr>(&n->value)
}

fn io_break_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::BreakStmt) {
    ar->flag(&n->has_label)
    ar->tok(&n->label)
}

fn io_continue_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::ContinueStmt) {
    ar->flag(&n->has_label)
    ar->tok(&n->label)
}

fn io_panic_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::PanicStmt) {
    ar->expr<Expr>(&n->payload)
    eval if defined!(DEBUG) {
        ar->sema_null<Decl>(n->repanic, "PanicStmt::repanic")
    }
}

fn io_yield_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::YieldStmt) {
    ar->expr<Expr>(&n->value)
}

fn io_runtime_assert_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::RuntimeAssertStmt) {
    ar->expr<Expr>(&n->condition)
    ar->expr<Expr>(&n->message)
}

fn io_static_assert_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::StaticAssertStmt) {
    ar->expr<Expr>(&n->condition)
    ar->expr<Expr>(&n->message)
}

fn io_label_intrinsic_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::LabelIntrinsicStmt) {
    ar->tok(&n->name)
}

fn io_jump_intrinsic_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::JumpIntrinsicStmt) {
    ar->tok(&n->target)
    eval if defined!(DEBUG) {
        ar->sema_false(n->ef_leave, "JumpIntrinsicStmt::ef_leave")
    }
}

fn io_conditional_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::ConditionalStmt) {
    ar->flag(&n->is_eval)
    ar->expr<Expr>(&n->cond)
    ar->stmt<Statements::CompoundStmt>(&n->then_)
    ar->stmt<Stmt>(&n->else_)
    ar->num8(&n->else_hint)
    eval if defined!(DEBUG) {
        ar->sema_false(n->eval_deferred, "ConditionalStmt::eval_deferred")
        ar->sema_zero((n->eval_taken as u8) as u64, "ConditionalStmt::eval_taken")
    }
}

fn io_while_loop_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::WhileLoopStmt) {
    ar->expr<Expr>(&n->cond)
    ar->stmt<Statements::CompoundStmt>(&n->body)
}

fn io_loop_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::LoopStmt) {
    ar->stmt<Statements::CompoundStmt>(&n->body)
}

fn io_ranged_for_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::RangedForStmt) {
    ar->flag(&n->is_eval)
    io_bindings(ar, &n->bindings)
    ar->expr<Expr>(&n->iterable)
    ar->stmt<Statements::CompoundStmt>(&n->body)
    eval if defined!(DEBUG) {
        // The iteration protocol X selects and IterLowering places.
        ar->sema_null<Expr>(n->ev_lo, "RangedForStmt::ev_lo")
        ar->sema_null<Expr>(n->ev_hi, "RangedForStmt::ev_hi")
        ar->sema_false(n->ev_incl, "RangedForStmt::ev_incl")
        ar->sema_is(n->iter_kind == Statements::IterKind::None, "RangedForStmt::iter_kind")
        ar->sema_null<Decl>(n->iter_op, "RangedForStmt::iter_op")
        ar->sema_null<Type>(n->iter_elem, "RangedForStmt::iter_elem")
        ar->sema_is(n->iter_inst == &null, "RangedForStmt::iter_inst")
        ar->sema_null<Decl>(n->cxx_begin_fn, "RangedForStmt::cxx_begin_fn")
        ar->sema_null<Decl>(n->cxx_end_fn, "RangedForStmt::cxx_end_fn")
        ar->sema_false(n->cxx_free, "RangedForStmt::cxx_free")
        ar->sema_false(n->cxx_dependent, "RangedForStmt::cxx_dependent")
        ar->sema_is(n->cxx_begin_inst == &null, "RangedForStmt::cxx_begin_inst")
        ar->sema_is(n->cxx_end_inst == &null, "RangedForStmt::cxx_end_inst")
        ar->sema_null<VariableDecl>(n->cxx_it, "RangedForStmt::cxx_it")
        ar->sema_null<VariableDecl>(n->cxx_end, "RangedForStmt::cxx_end")
        ar->sema_null<Expr>(n->cxx_cond, "RangedForStmt::cxx_cond")
        ar->sema_null<Expr>(n->cxx_deref, "RangedForStmt::cxx_deref")
        ar->sema_null<Expr>(n->cxx_next, "RangedForStmt::cxx_next")
    }
}

fn io_indexed_for_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::IndexedForStmt) {
    ar->flag(&n->is_eval)
    ar->stmt<Stmt>(&n->init)
    ar->expr<Expr>(&n->cond)
    ar->expr<Expr>(&n->update)
    ar->stmt<Statements::CompoundStmt>(&n->body)
}

fn io_match_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::MatchStmt) {
    ar->expr<Expr>(&n->scrutinee)
    io_match_cases(ar, &n->cases)
    eval if defined!(DEBUG) {
        ar->sema_is(n->is_exhaustive, "MatchStmt::is_exhaustive")
        ar->sema_is(n->covering_arm == -1, "MatchStmt::covering_arm")
        ar->sema_false(n->open_tail, "MatchStmt::open_tail")
        ar->sema_null<void>(n->decision, "MatchStmt::decision")
        ar->sema_false(n->null_arm, "MatchStmt::null_arm")
    }
}

fn io_labeled_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::LabeledStmt) {
    ar->tok(&n->label)
    ar->stmt<Stmt>(&n->inner)
}

fn io_try_catch_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::TryCatchStmt) {
    ar->stmt<Statements::CompoundStmt>(&n->try_body)

    var count = ar->list<Statements::CatchArm>(&n->arms)
    for var i: usize = 0; i < count; ++i {
        var unsafe *a = n->arms.get(i)
        ar->type_<Type>(&a->filter)
        ar->expr<NamedIdentExpr>(&a->binding)
        ar->stmt<Statements::CompoundStmt>(&a->body)
        ar->range(&a->range)
        ar->decl<Decl>(&a->decl)
        eval if defined!(DEBUG) {
            ar->sema_false(a->is_dead, "CatchArm::is_dead")
            ar->sema_false(a->is_cxx, "CatchArm::is_cxx")
        }
    }

    eval if defined!(DEBUG) {
        ar->sema_zero(n->reach.size() as u64, "TryCatchStmt::reach")
        ar->sema_false(n->cxx, "TryCatchStmt::cxx")
    }
}

fn io_finally_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::FinallyStmt) {
    ar->stmt<Statements::CompoundStmt>(&n->body)
}

fn io_unsafe_block_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::UnsafeBlockStmt) {
    ar->stmt<Statements::CompoundStmt>(&n->body)
}

fn io_context_binding_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::ContextBindingStmt) {
    ar->expr<Expr>(&n->value)
    io_bindings(ar, &n->bindings)
    ar->stmt<Statements::CompoundStmt>(&n->body)
}

fn io_destructuring_decl_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::DestructuringDeclStmt) {
    ar->en<Statements::DestructureKind>(&n->kind_)
    ar->flag(&n->leading_is_const)
    io_bindings(ar, &n->bindings)
    ar->expr<Expr>(&n->value)
}

fn io_inline_block_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::InlineBlockStmt) {
    ar->en<Statements::FFILang>(&n->lang)
    ar->range(&n->body_span)
}

fn io_eval_block_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::EvalBlockStmt) {
    ar->decl_list<Decl>(&n->body)
}

/// Minted by MatchLowering; no parsed tree has one. Written in full all the
/// same: every field is a child or a label, nothing in it is a Sema fact.
fn io_switch_dispatch_stmt(ar: unsafe *ASTArchive, n: unsafe *Statements::SwitchDispatchStmt) {
    ar->expr<Expr>(&n->value)

    var count = ar->list<Statements::DispatchCase>(&n->cases)
    for var i: usize = 0; i < count; ++i {
        var unsafe *c = n->cases.get(i)
        ar->expr<Expr>(&c->lo)
        ar->expr<Expr>(&c->hi)
        ar->tok(&c->target)
    }

    ar->tok(&n->default_target)
    ar->stmt<Stmt>(&n->default_stmt)
}

/// Writes or reads one statement: the family header, then its class.
pub fn stmt_io(ar: unsafe *ASTArchive, s: unsafe *Stmt) {
    io_stmt_base(ar, s)

    var cls = s->kind
    if cls == StmtKind::RecoveryStmt {
        cls = s->recovery_kind
    }

    match cls {
        case StmtKind::CompoundStmt {
            io_compound_stmt(ar, unsafe (s as unsafe *Statements::CompoundStmt))
        } case StmtKind::ExpressionStmt {
            io_expression_stmt(ar, unsafe (s as unsafe *Statements::ExpressionStmt))
        } case StmtKind::DeclStmt {
            io_decl_stmt(ar, unsafe (s as unsafe *Statements::DeclStmt))
        } case StmtKind::ReturnStmt {
            io_return_stmt(ar, unsafe (s as unsafe *Statements::ReturnStmt))
        } case StmtKind::BreakStmt {
            io_break_stmt(ar, unsafe (s as unsafe *Statements::BreakStmt))
        } case StmtKind::ContinueStmt {
            io_continue_stmt(ar, unsafe (s as unsafe *Statements::ContinueStmt))
        } case StmtKind::PanicStmt {
            io_panic_stmt(ar, unsafe (s as unsafe *Statements::PanicStmt))
        } case StmtKind::YieldStmt {
            io_yield_stmt(ar, unsafe (s as unsafe *Statements::YieldStmt))
        } case StmtKind::RuntimeAssertStmt {
            io_runtime_assert_stmt(ar, unsafe (s as unsafe *Statements::RuntimeAssertStmt))
        } case StmtKind::StaticAssertStmt {
            io_static_assert_stmt(ar, unsafe (s as unsafe *Statements::StaticAssertStmt))
        } case StmtKind::LabelIntrinsicStmt {
            io_label_intrinsic_stmt(ar, unsafe (s as unsafe *Statements::LabelIntrinsicStmt))
        } case StmtKind::JumpIntrinsicStmt {
            io_jump_intrinsic_stmt(ar, unsafe (s as unsafe *Statements::JumpIntrinsicStmt))
        } case StmtKind::ConditionalStmt {
            io_conditional_stmt(ar, unsafe (s as unsafe *Statements::ConditionalStmt))
        } case StmtKind::WhileLoopStmt {
            io_while_loop_stmt(ar, unsafe (s as unsafe *Statements::WhileLoopStmt))
        } case StmtKind::LoopStmt {
            io_loop_stmt(ar, unsafe (s as unsafe *Statements::LoopStmt))
        } case StmtKind::RangedForStmt {
            io_ranged_for_stmt(ar, unsafe (s as unsafe *Statements::RangedForStmt))
        } case StmtKind::IndexedForStmt {
            io_indexed_for_stmt(ar, unsafe (s as unsafe *Statements::IndexedForStmt))
        } case StmtKind::MatchStmt {
            io_match_stmt(ar, unsafe (s as unsafe *Statements::MatchStmt))
        } case StmtKind::LabeledStmt {
            io_labeled_stmt(ar, unsafe (s as unsafe *Statements::LabeledStmt))
        } case StmtKind::TryCatchStmt {
            io_try_catch_stmt(ar, unsafe (s as unsafe *Statements::TryCatchStmt))
        } case StmtKind::FinallyStmt {
            io_finally_stmt(ar, unsafe (s as unsafe *Statements::FinallyStmt))
        } case StmtKind::UnsafeBlockStmt {
            io_unsafe_block_stmt(ar, unsafe (s as unsafe *Statements::UnsafeBlockStmt))
        } case StmtKind::ContextBindingStmt {
            io_context_binding_stmt(ar, unsafe (s as unsafe *Statements::ContextBindingStmt))
        } case StmtKind::DestructuringDeclStmt {
            io_destructuring_decl_stmt(ar, unsafe (s as unsafe *Statements::DestructuringDeclStmt))
        } case StmtKind::InlineBlockStmt {
            io_inline_block_stmt(ar, unsafe (s as unsafe *Statements::InlineBlockStmt))
        } case StmtKind::EvalBlockStmt {
            io_eval_block_stmt(ar, unsafe (s as unsafe *Statements::EvalBlockStmt))
        } case StmtKind::SwitchDispatchStmt {
            io_switch_dispatch_stmt(ar, unsafe (s as unsafe *Statements::SwitchDispatchStmt))
        } default {
            ar->fail("statement of an unknown kind")
        }
    }
}
