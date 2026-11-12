/// --- The Kairo Project ----------------------- AST/Serialize/ExprIO.k --- ///
///
///   The Expr family: one `io_` function per expression class, the structs
///   expressions hold by value (chain steps, initializer fields, arms,
///   captures), and the entry points the archive's hooks call (expr_alloc,
///   expr_io).
///
///   The rule for a field is DeclIO.k's: stored through a primitive when the
///   parser writes it, named in the DEBUG block when a later stage does.
///   Most of what an expression node carries beyond its children is the
///   second kind: X (the expression typer) and the lowerings annotate
///   expressions more than anything else in the tree.
///
///   One class is not written: VariantInitExpr, which VariantInitLowering
///   mints around a resolved enum declaration that may be another file's.
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
import AST::Context::ASTContext::ASTContext
import AST::Kind::ExprKind::ExprKind
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::Declarations::{
    FnBodyKind,
    FnModifier,
    GenericParamDecl,
    PanicSetState,
    ParamDecl,
}
import AST::Node::Expressions
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr,
    ChainExpr,
    CharacterLiteralExpr,
    FloatingLiteralExpr,
    IntegerLiteralExpr,
    NamedIdentExpr,
    NullLiteralExpr,
    StringLiteralExpr,
}
import AST::Node::Statements::CompoundStmt
import AST::Serialize::Archive::ASTArchive
import AST::Serialize::NodeCommon::io_annotations
import AST::Serialize::StmtIO::io_match_cases
import AST::Serialize::TypeIO::io_generic_args
import Lexer::Immediate::Immediate
import Token::Token::Token

fn <T: type> new_expr(ar: unsafe *ASTArchive) -> unsafe *Expr {
    var unsafe *n = ar->ctx->alloc<T>()
    n->init_annotations(unsafe &ar->ctx->ast_alloc)
    return unsafe (n as unsafe *Expr)
}

/// Reads an expression's kind and allocates an object of its class.
pub fn expr_alloc(ar: unsafe *ASTArchive) -> unsafe *Expr {
    var kind = ExprKind::RecoveryExpr
    ar->en<ExprKind>(&kind)
    var cls = kind
    if kind == ExprKind::RecoveryExpr {
        ar->en<ExprKind>(&cls)
    }

    var e: unsafe *Expr = &null
    match cls {
        case ExprKind::IntegerLiteralExpr {
            e = new_expr<IntegerLiteralExpr>(ar)
        } case ExprKind::FloatingLiteralExpr {
            e = new_expr<FloatingLiteralExpr>(ar)
        } case ExprKind::StringLiteralExpr {
            e = new_expr<StringLiteralExpr>(ar)
        } case ExprKind::CharacterLiteralExpr {
            e = new_expr<CharacterLiteralExpr>(ar)
        } case ExprKind::BooleanLiteralExpr {
            e = new_expr<BooleanLiteralExpr>(ar)
        } case ExprKind::NullLiteralExpr {
            e = new_expr<NullLiteralExpr>(ar)
        } case ExprKind::ListLiteralExpr {
            e = new_expr<Expressions::ListLiteralExpr>(ar)
        } case ExprKind::TupleLiteralExpr {
            e = new_expr<Expressions::TupleLiteralExpr>(ar)
        } case ExprKind::SetLiteralExpr {
            e = new_expr<Expressions::SetLiteralExpr>(ar)
        } case ExprKind::MapLiteralExpr {
            e = new_expr<Expressions::MapLiteralExpr>(ar)
        } case ExprKind::NamedInitializerExpr {
            e = new_expr<Expressions::NamedInitializerExpr>(ar)
        } case ExprKind::AnonInitializerExpr {
            e = new_expr<Expressions::AnonInitializerExpr>(ar)
        } case ExprKind::ChainExpr {
            e = new_expr<ChainExpr>(ar)
        } case ExprKind::CallExpr {
            e = new_expr<Expressions::CallExpr>(ar)
        } case ExprKind::SubscriptExpr {
            e = new_expr<Expressions::SubscriptExpr>(ar)
        } case ExprKind::NamedIdentExpr {
            e = new_expr<NamedIdentExpr>(ar)
        } case ExprKind::UnaryOperatorExpr {
            e = new_expr<Expressions::UnaryOperatorExpr>(ar)
        } case ExprKind::BinaryOperatorExpr {
            e = new_expr<Expressions::BinaryOperatorExpr>(ar)
        } case ExprKind::AssignOperatorExpr {
            e = new_expr<Expressions::AssignOperatorExpr>(ar)
        } case ExprKind::ImplConformanceExpr {
            e = new_expr<Expressions::ImplConformanceExpr>(ar)
        } case ExprKind::DerivesRelationExpr {
            e = new_expr<Expressions::DerivesRelationExpr>(ar)
        } case ExprKind::IfExpr {
            e = new_expr<Expressions::IfExpr>(ar)
        } case ExprKind::TryCatchExpr {
            e = new_expr<Expressions::TryCatchExpr>(ar)
        } case ExprKind::MatchExpr {
            e = new_expr<Expressions::MatchExpr>(ar)
        } case ExprKind::RangeExpr {
            e = new_expr<Expressions::RangeExpr>(ar)
        } case ExprKind::ClosureExpr {
            e = new_expr<Expressions::ClosureExpr>(ar)
        } case ExprKind::AwaitExpr {
            e = new_expr<Expressions::AwaitExpr>(ar)
        } case ExprKind::SpawnExpr {
            e = new_expr<Expressions::SpawnExpr>(ar)
        } case ExprKind::ThreadExpr {
            e = new_expr<Expressions::ThreadExpr>(ar)
        } case ExprKind::ConstraintExpr {
            e = new_expr<Expressions::ConstraintExpr>(ar)
        } case ExprKind::SizeOfExpr {
            e = new_expr<Expressions::SizeOfExpr>(ar)
        } case ExprKind::AlignOfExpr {
            e = new_expr<Expressions::AlignOfExpr>(ar)
        } case ExprKind::TypeOfExpr {
            e = new_expr<Expressions::TypeOfExpr>(ar)
        } case ExprKind::EvalExpr {
            e = new_expr<Expressions::EvalExpr>(ar)
        } case ExprKind::UnsafeExpr {
            e = new_expr<Expressions::UnsafeExpr>(ar)
        } case ExprKind::DeleteExpr {
            e = new_expr<Expressions::DeleteExpr>(ar)
        } case ExprKind::PackExpansionExpr {
            e = new_expr<Expressions::PackExpansionExpr>(ar)
        } case ExprKind::TypeCastExpr {
            e = new_expr<Expressions::TypeCastExpr>(ar)
        } case ExprKind::ImplicitBoundaryCastExpr {
            e = new_expr<Expressions::ImplicitBoundaryCastExpr>(ar)
        } case ExprKind::ParenExpr {
            e = new_expr<Expressions::ParenExpr>(ar)
        } case ExprKind::VerbatimExpr {
            e = new_expr<Expressions::VerbatimExpr>(ar)
        } case ExprKind::NamedArgExpr {
            e = new_expr<Expressions::NamedArgExpr>(ar)
        } case ExprKind::InitListExpr {
            e = new_expr<Expressions::InitListExpr>(ar)
        } case ExprKind::StmtExpr {
            e = new_expr<Expressions::StmtExpr>(ar)
        } case ExprKind::UnwrapExpr {
            e = new_expr<Expressions::UnwrapExpr>(ar)
        } case ExprKind::DefinedExpr {
            e = new_expr<Expressions::DefinedExpr>(ar)
        } case ExprKind::AttributedExpr {
            e = new_expr<Expressions::AttributedExpr>(ar)
        } case ExprKind::PanicOpExpr {
            e = new_expr<Expressions::PanicOpExpr>(ar)
        } case ExprKind::TypeTraitExpr {
            e = new_expr<Expressions::TypeTraitExpr>(ar)
        } case ExprKind::CxxNewExpr {
            e = new_expr<Expressions::CxxNewExpr>(ar)
        } default {
            return &null
        }
    }

    e->kind = kind
    if kind == ExprKind::RecoveryExpr {
        e->recovery_kind = cls
    }

    return e
}

fn io_expr_base(ar: unsafe *ASTArchive, e: unsafe *Expr) {
    if !ar->reading() {
        ar->en<ExprKind>(&e->kind)
        if e->kind == ExprKind::RecoveryExpr {
            ar->en<ExprKind>(&e->recovery_kind)
        }
    }

    ar->range(&e->range)
    ar->flag(&e->poisoned)
    io_annotations<Expr>(ar, e)
    eval if defined!(DEBUG) {
        // X's facts (Pipeline.md, fact writers).
        ar->sema_is(e->value_category == Expr::ValueCategory::Unknown, "Expr::value_category")
        ar->sema_null<Type>(e->type_, "Expr::type_")
        ar->sema_zero(e->expr_flags.bits as u64, "Expr::expr_flags")
        if e->kind != ExprKind::RecoveryExpr {
            ar->sema_is(e->recovery_kind == ExprKind::RecoveryExpr, "Expr::recovery_kind")
        }
    }
}

//  structs held by value

/// The `name: value` fields of a named or anonymous initializer.
fn io_init_fields(ar: unsafe *ASTArchive, @inout l: FrozenList<Expressions::InitField>) {
    var n = ar->list<Expressions::InitField>(&l)
    for var i: usize = 0; i < n; ++i {
        var unsafe *f = l.get(i)
        ar->tok(&f->name)
        ar->expr<Expr>(&f->value)
        ar->range(&f->range)
        eval if defined!(DEBUG) {
            ar->sema_null<Decl>(f->field_decl, "InitField::field_decl")
        }
    }
}

//  primary expressions

/// A literal node's `imm` points at its token's payload slot, in the table
/// of the file that wrote the literal. It is not stored: the token is, and
/// the slot is found from it exactly as the node's factory finds it.
fn io_integer_literal_expr(ar: unsafe *ASTArchive, n: unsafe *IntegerLiteralExpr) {
    ar->tok(&n->token)
    var has = n->imm != &null
    ar->flag(&has)
    if ar->reading() {
        n->ctx = ar->ctx
        if has {
            n->imm = ar->ctx->get_payload_table(n->token)->get<Immediate::IntData>(
                ar->ctx->unwrap_token(n->token).imm,
            )
        }
    }

    eval if defined!(DEBUG) {
        ar->sema_is(n->pinned_kind == 255, "IntegerLiteralExpr::pinned_kind")
        if has && !ar->reading() {
            ar->sema_is(
                n->imm == ar->ctx->get_payload_table(n->token)->get<Immediate::IntData>(
                    ar->ctx->unwrap_token(n->token).imm,
                ),
                "IntegerLiteralExpr::imm is not its token's slot",
            )
        }
    }
}

fn io_floating_literal_expr(ar: unsafe *ASTArchive, n: unsafe *FloatingLiteralExpr) {
    ar->tok(&n->token)
    var has = n->imm != &null
    ar->flag(&has)
    if ar->reading() {
        n->ctx = ar->ctx
        if has {
            n->imm = ar->ctx->get_payload_table(n->token)->get<Immediate::FloatData>(
                ar->ctx->unwrap_token(n->token).imm,
            )
        }
    }

    eval if defined!(DEBUG) {
        ar->sema_is(n->pinned_kind == 255, "FloatingLiteralExpr::pinned_kind")
        ar->sema_zero(n->limit as u64, "FloatingLiteralExpr::limit")
        if has && !ar->reading() {
            ar->sema_is(
                n->imm == ar->ctx->get_payload_table(n->token)->get<Immediate::FloatData>(
                    ar->ctx->unwrap_token(n->token).imm,
                ),
                "FloatingLiteralExpr::imm is not its token's slot",
            )
        }
    }
}

fn io_string_literal_expr(ar: unsafe *ASTArchive, n: unsafe *StringLiteralExpr) {
    ar->tok(&n->token)
    ar->num8(&n->string_kind.bits)
    var has = n->imm != &null
    ar->flag(&has)
    if ar->reading() {
        n->ctx = ar->ctx
        if has {
            n->imm = ar->ctx->get_payload_table(n->token)->get<Immediate::StringData>(
                ar->ctx->unwrap_token(n->token).imm,
            )
        }
    }

    // The holes of an f-string, parsed: the parser's, from the slot's token
    // runs (which the payload carries too, for whoever re-reads them).
    ar->expr_list<Expr>(&n->parts)

    eval if defined!(DEBUG) {
        ar->sema_null<Decl>(n->string_ctor, "StringLiteralExpr::string_ctor")
        ar->sema_null<Decl>(n->fmt_ctor, "StringLiteralExpr::fmt_ctor")
        ar->sema_null<Decl>(n->fmt_text, "StringLiteralExpr::fmt_text")
        ar->sema_null<Decl>(n->fmt_finish, "StringLiteralExpr::fmt_finish")
        ar->sema_null<Decl>(n->fmt_len, "StringLiteralExpr::fmt_len")
        ar->sema_zero(n->fmt_holes.size() as u64, "StringLiteralExpr::fmt_holes")
        ar->sema_false(n->const_eval, "StringLiteralExpr::const_eval")
        ar->sema_null<Type>(n->c_string, "StringLiteralExpr::c_string")
        ar->sema_null<Decl>(n->udl_op, "StringLiteralExpr::udl_op")
        if has && !ar->reading() {
            ar->sema_is(
                n->imm == ar->ctx->get_payload_table(n->token)->get<Immediate::StringData>(
                    ar->ctx->unwrap_token(n->token).imm,
                ),
                "StringLiteralExpr::imm is not its token's slot",
            )
        }
    }
}

fn io_character_literal_expr(ar: unsafe *ASTArchive, n: unsafe *CharacterLiteralExpr) {
    ar->tok(&n->token)
    if ar->reading() {
        n->ctx = unsafe (ar->ctx as *ASTContext)
    }

    eval if defined!(DEBUG) {
        // The parser leaves it null; its readers resolve the slot themselves.
        ar->sema_is(n->imm == &null, "CharacterLiteralExpr::imm")
    }
}

fn io_boolean_literal_expr(ar: unsafe *ASTArchive, n: unsafe *BooleanLiteralExpr) {
    ar->flag(&n->value)
}

fn io_null_literal_expr(ar: unsafe *ASTArchive, n: unsafe *NullLiteralExpr) {
    ar->flag(&n->is_ref)
}

fn io_named_ident_expr(ar: unsafe *ASTArchive, n: unsafe *NamedIdentExpr) {
    ar->tok(&n->name)
    io_generic_args(ar, &n->generic_args)
    if ar->reading() {
        n->ctx = ar->ctx
    }

    eval if defined!(DEBUG) {
        ar->sema_null<Decl>(n->resolved_decl, "NamedIdentExpr::resolved_decl")
        ar->sema_is(n->candidate_cell == &null, "NamedIdentExpr::candidate_cell")
        ar->sema_null<Decl>(n->variant_decl, "NamedIdentExpr::variant_decl")
        ar->sema_null<Type>(n->narrowed_from, "NamedIdentExpr::narrowed_from")
        ar->sema_false(n->capture_ptr, "NamedIdentExpr::capture_ptr")
    }
}

fn io_chain_expr(ar: unsafe *ASTArchive, n: unsafe *ChainExpr) {
    ar->expr<Expr>(&n->base)
    if ar->reading() {
        n->ctx = ar->ctx
    }

    var count = ar->list<ChainExpr::Step>(&n->steps)
    for var i: usize = 0; i < count; ++i {
        var unsafe *s = n->steps.get(i)
        ar->expr<NamedIdentExpr>(&s->name)
        ar->en<ChainExpr::StepTarget>(&s->target)
        ar->tok_list(&s->op_tokens)
        io_generic_args(ar, &s->generic_args)
        ar->range(&s->range)
        ar->en<ChainExpr::AccessKind>(&s->access_kind)
        ar->num32(&s->index)
        eval if defined!(DEBUG) {
            // What a step binds to is ChainBinding's and X's.
            ar->sema_is(s->pack_index == -1, "ChainExpr::Step::pack_index")
            ar->sema_null<Type>(s->resolved_type, "ChainExpr::Step::resolved_type")
            ar->sema_null<Decl>(s->resolved_decl, "ChainExpr::Step::resolved_decl")
            ar->sema_is(s->candidate_cell == &null, "ChainExpr::Step::candidate_cell")
            ar->sema_null<Type>(s->narrowed_from, "ChainExpr::Step::narrowed_from")
            ar->sema_null<Type>(s->through, "ChainExpr::Step::through")
            ar->sema_null<Type>(s->witness_iface, "ChainExpr::Step::witness_iface")
            ar->sema_null<Type>(s->witness_self, "ChainExpr::Step::witness_self")
        }
    }

    eval if defined!(DEBUG) {
        ar->sema_null<Decl>(n->variant_decl, "ChainExpr::variant_decl")
    }
}

//  expressions

fn io_call_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::CallExpr) {
    ar->expr<Expr>(&n->callee)
    ar->expr_list<Expr>(&n->args)
    eval if defined!(DEBUG) {
        // Everything CallTyping selects and the lowerings read.
        ar->sema_zero(n->arg_map.size() as u64, "CallExpr::arg_map")
        ar->sema_zero(n->pack_len as u64, "CallExpr::pack_len")
        ar->sema_is(n->instance == &null, "CallExpr::instance")
        ar->sema_null<Decl>(n->ctor_decl, "CallExpr::ctor_decl")
        ar->sema_null<Decl>(n->functor_op, "CallExpr::functor_op")
        ar->sema_null<Type>(n->qualifier, "CallExpr::qualifier")
        ar->sema_false(n->fmt_dyn, "CallExpr::fmt_dyn")
        ar->sema_null<Type>(n->witness_iface, "CallExpr::witness_iface")
        ar->sema_null<Type>(n->witness_self, "CallExpr::witness_self")
        ar->sema_is(n->witness_row == &null, "CallExpr::witness_row")
        ar->sema_zero(n->dep_args.size() as u64, "CallExpr::dep_args")
        ar->sema_null<Type>(n->safe_result, "CallExpr::safe_result")
        ar->sema_false(n->recv_last, "CallExpr::recv_last")
    }
}

fn io_named_arg_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::NamedArgExpr) {
    ar->tok(&n->name)
    ar->expr<Expr>(&n->value)
}

fn io_subscript_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::SubscriptExpr) {
    ar->expr<Expr>(&n->base)
    ar->expr<Expr>(&n->index)
    eval if defined!(DEBUG) {
        ar->sema_null<Decl>(n->resolved_op, "SubscriptExpr::resolved_op")
        ar->sema_false(n->op_via_free, "SubscriptExpr::op_via_free")
        ar->sema_is(n->op_instance == &null, "SubscriptExpr::op_instance")
        ar->sema_zero(n->place_ctx as u64, "SubscriptExpr::place_ctx")
    }
}

fn io_list_literal_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::ListLiteralExpr) {
    ar->expr_list<Expr>(&n->elements)
    eval if defined!(DEBUG) {
        ar->sema_is(n->storage == Expressions::ListStorage::FullExpr, "ListLiteralExpr::storage")
        ar->sema_null<Decl>(n->slice_ctor, "ListLiteralExpr::slice_ctor")
        ar->sema_null<Decl>(n->owner_ctor, "ListLiteralExpr::owner_ctor")
    }
}

fn io_init_list_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::InitListExpr) {
    ar->expr_list<Expr>(&n->elements)
}

fn io_stmt_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::StmtExpr) {
    ar->stmt<CompoundStmt>(&n->body)
    ar->flag(&n->is_jump)
}

fn io_tuple_literal_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::TupleLiteralExpr) {
    ar->expr_list<Expr>(&n->elements)
}

fn io_set_literal_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::SetLiteralExpr) {
    ar->expr_list<Expr>(&n->elements)
}

fn io_map_literal_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::MapLiteralExpr) {
    var count = ar->list<Expressions::MapLiteralExpr::Entry>(&n->entries)
    for var i: usize = 0; i < count; ++i {
        var unsafe *e = n->entries.get(i)
        ar->expr<Expr>(&e->key)
        ar->expr<Expr>(&e->value)
        ar->range(&e->range)
    }
}

fn io_named_initializer_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::NamedInitializerExpr) {
    ar->expr<Expr>(&n->type_expr)
    io_init_fields(ar, &n->fields)
    ar->flag(&n->is_dotted)
    ar->flag(&n->has_braces)
    ar->tok(&n->dotted_name)
    if ar->reading() {
        n->ctx = ar->ctx
    }

    eval if defined!(DEBUG) {
        ar->sema_null<Decl>(n->variant_decl, "NamedInitializerExpr::variant_decl")
        ar->sema_is(n->variant_pack == -1, "NamedInitializerExpr::variant_pack")
    }
}

fn io_anon_initializer_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::AnonInitializerExpr) {
    io_init_fields(ar, &n->fields)
    if ar->reading() {
        n->ctx = unsafe (ar->ctx as *ASTContext)
    }
}

fn io_unary_operator_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::UnaryOperatorExpr) {
    ar->expr<Expr>(&n->operand)
    ar->tok(&n->op_token)
    ar->en<Expressions::UnaryOperatorExpr::Fix>(&n->fix)
    eval if defined!(DEBUG) {
        ar->sema_false(n->is_mode_marker, "UnaryOperatorExpr::is_mode_marker")
        ar->sema_false(n->materialize, "UnaryOperatorExpr::materialize")
        ar->sema_false(n->no_wrap, "UnaryOperatorExpr::no_wrap")
        ar->sema_null<Decl>(n->resolved_op, "UnaryOperatorExpr::resolved_op")
        ar->sema_false(n->op_via_free, "UnaryOperatorExpr::op_via_free")
        ar->sema_is(n->op_instance == &null, "UnaryOperatorExpr::op_instance")
        ar->sema_null<Type>(n->narrowed_from, "UnaryOperatorExpr::narrowed_from")
    }
}

/// The left spine of a binary chain is walked in a loop, not by recursion:
/// `a + b + c + ...` nests as deep as it is long, and the parser builds it
/// with a loop, so a long one is a tree deeper than any stack. The bytes
/// are the ones recursion would write: each node of the spine, its `lhs`
/// reference first, then on the way back up its `rhs` and operator.
fn io_binary_operator_expr(ar: unsafe *ASTArchive, top: unsafe *Expressions::BinaryOperatorExpr) {
    var spine: [unsafe *Expressions::BinaryOperatorExpr]
    var cur = top
    while true {
        spine.push_back(cur)
        var fresh = ar->expr_begin(&cur->lhs)
        if !fresh {
            break
        }

        var l: unsafe *Expr = cur->lhs
        io_expr_base(ar, l)
        if expr_class(l) != ExprKind::BinaryOperatorExpr {
            io_expr_fields(ar, l)
            break
        }

        cur = unsafe (l as unsafe *Expressions::BinaryOperatorExpr)
    }

    while spine.size() > 0 {
        var n = spine[spine.size() - 1]
        spine.pop_back()
        ar->expr<Expr>(&n->rhs)
        ar->tok(&n->op_token)
        eval if defined!(DEBUG) {
            ar->sema_null<Decl>(n->resolved_op, "BinaryOperatorExpr::resolved_op")
            ar->sema_false(n->op_via_free, "BinaryOperatorExpr::op_via_free")
            ar->sema_is(n->op_rewrite == Expressions::OpRewrite::None, "BinaryOperatorExpr::op_rewrite")
            ar->sema_false(n->tag_eq, "BinaryOperatorExpr::tag_eq")
            ar->sema_false(n->no_wrap, "BinaryOperatorExpr::no_wrap")
            ar->sema_is(n->op_instance == &null, "BinaryOperatorExpr::op_instance")
            ar->sema_null<Type>(n->type_cmp_lhs, "BinaryOperatorExpr::type_cmp_lhs")
            ar->sema_null<Type>(n->type_cmp_rhs, "BinaryOperatorExpr::type_cmp_rhs")
        }
    }
}

fn io_assign_operator_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::AssignOperatorExpr) {
    ar->expr<Expr>(&n->lhs)
    ar->expr<Expr>(&n->rhs)
    ar->tok(&n->op_token)
    eval if defined!(DEBUG) {
        ar->sema_null<Decl>(n->resolved_op, "AssignOperatorExpr::resolved_op")
        ar->sema_false(n->op_via_free, "AssignOperatorExpr::op_via_free")
        ar->sema_is(n->op_instance == &null, "AssignOperatorExpr::op_instance")
        ar->sema_false(n->ci_elem_init, "AssignOperatorExpr::ci_elem_init")
        ar->sema_false(n->no_wrap, "AssignOperatorExpr::no_wrap")
    }
}

fn io_impl_conformance_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::ImplConformanceExpr) {
    ar->type_<Type>(&n->subject)
    ar->type_<Type>(&n->inter)
}

fn io_derives_relation_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::DerivesRelationExpr) {
    ar->type_<Type>(&n->subject)
    ar->type_<Type>(&n->base)
}

fn io_if_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::IfExpr) {
    ar->expr<Expr>(&n->condition)
    ar->expr<Expr>(&n->then_expr)

    var count = ar->list<Expressions::IfExpr::ElseIf>(&n->else_ifs)
    for var i: usize = 0; i < count; ++i {
        var unsafe *a = n->else_ifs.get(i)
        ar->expr<Expr>(&a->condition)
        ar->expr<Expr>(&a->body)
        ar->range(&a->range)
    }

    ar->expr<Expr>(&n->else_expr)
}

/// Minted by PanicLowering; no parsed tree has one. `elem` is a type the
/// lowering formed, so a tree that reaches one fails in TypeIO.
fn io_panic_op_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::PanicOpExpr) {
    ar->en<Expressions::PanicOp>(&n->which)
    ar->expr<Expr>(&n->operand)
    ar->expr<Expr>(&n->slot)
    ar->type_<Type>(&n->elem)
}

fn io_try_catch_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::TryCatchExpr) {
    ar->expr<Expr>(&n->try_expr)

    var count = ar->list<Expressions::TryCatchExpr::CatchArm>(&n->catch_arms)
    for var i: usize = 0; i < count; ++i {
        var unsafe *a = n->catch_arms.get(i)
        ar->flag(&a->has_binding)
        ar->flag(&a->is_const)
        ar->expr<NamedIdentExpr>(&a->binding)
        ar->type_<Type>(&a->filter)
        ar->expr<Expr>(&a->body)
        ar->range(&a->range)
        ar->decl<Decl>(&a->decl)
        eval if defined!(DEBUG) {
            ar->sema_false(a->is_dead, "TryCatchExpr::CatchArm::is_dead")
            ar->sema_false(a->is_cxx, "TryCatchExpr::CatchArm::is_cxx")
        }
    }

    eval if defined!(DEBUG) {
        ar->sema_zero(n->reach.size() as u64, "TryCatchExpr::reach")
    }
}

fn io_match_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::MatchExpr) {
    ar->expr<Expr>(&n->scrutinee)
    io_match_cases(ar, &n->cases)
    eval if defined!(DEBUG) {
        ar->sema_is(n->is_exhaustive, "MatchExpr::is_exhaustive")
        ar->sema_is(n->covering_arm == -1, "MatchExpr::covering_arm")
        ar->sema_false(n->open_tail, "MatchExpr::open_tail")
        ar->sema_null<void>(n->decision, "MatchExpr::decision")
        ar->sema_false(n->null_arm, "MatchExpr::null_arm")
    }
}

fn io_range_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::RangeExpr) {
    ar->expr<Expr>(&n->begin)
    ar->expr<Expr>(&n->end)
    ar->flag(&n->is_inclusive)
    eval if defined!(DEBUG) {
        ar->sema_false(n->as_index, "RangeExpr::as_index")
    }
}

fn io_unwrap_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::UnwrapExpr) {
    ar->expr<Expr>(&n->operand)
}

fn io_defined_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::DefinedExpr) {
    ar->tok(&n->name)
}

fn io_attributed_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::AttributedExpr) {
    ar->tok(&n->name)
    ar->expr_list<Expr>(&n->args)
    ar->flag(&n->has_args)
    ar->expr<Expr>(&n->operand)
}

fn io_await_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::AwaitExpr) {
    ar->expr<Expr>(&n->operand)
}

fn io_spawn_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::SpawnExpr) {
    ar->expr<Expr>(&n->operand)
}

fn io_thread_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::ThreadExpr) {
    ar->expr<Expr>(&n->operand)
}

fn io_constraint_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::ConstraintExpr) {
    ar->expr<Expr>(&n->lhs)
    ar->type_<Type>(&n->rhs)
    ar->tok(&n->op_token)
}

fn io_size_of_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::SizeOfExpr) {
    ar->type_<Type>(&n->type_arg)
}

fn io_align_of_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::AlignOfExpr) {
    ar->type_<Type>(&n->type_arg)
}

fn io_type_trait_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::TypeTraitExpr) {
    ar->en<Expressions::TypeTraitKind>(&n->fact)
    ar->type_<Type>(&n->type_arg)
}

fn io_type_of_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::TypeOfExpr) {
    ar->expr<Expr>(&n->operand)
    eval if defined!(DEBUG) {
        ar->sema_is(n->resolved_type == &null, "TypeOfExpr::resolved_type")
    }
}

fn io_eval_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::EvalExpr) {
    ar->expr<Expr>(&n->operand)
}

fn io_unsafe_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::UnsafeExpr) {
    ar->expr<Expr>(&n->operand)
}

fn io_delete_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::DeleteExpr) {
    ar->expr<Expr>(&n->operand)
    ar->flag(&n->is_array)
    ar->flag(&n->is_cxx)
}

fn io_cxx_new_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::CxxNewExpr) {
    ar->expr<Expr>(&n->init)
    ar->expr<Expr>(&n->elem_size)
    ar->expr<Expr>(&n->count)
}

fn io_pack_expansion_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::PackExpansionExpr) {
    ar->expr<Expr>(&n->operand)
    eval if defined!(DEBUG) {
        ar->sema_false(n->reread, "PackExpansionExpr::reread")
    }
}

fn io_type_cast_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::TypeCastExpr) {
    ar->expr<Expr>(&n->operand)
    ar->type_<Type>(&n->target)
    ar->flag(&n->is_unsafe)
    ar->en<Expressions::CastMode>(&n->mode)
    eval if defined!(DEBUG) {
        // CastTyping's verdict on the cast.
        ar->sema_null<Decl>(n->resolved_op, "TypeCastExpr::resolved_op")
        ar->sema_false(n->op_via_free, "TypeCastExpr::op_via_free")
        ar->sema_null<Decl>(n->resolved_ctor, "TypeCastExpr::resolved_ctor")
        ar->sema_false(n->widening, "TypeCastExpr::widening")
        ar->sema_false(n->checked_downcast, "TypeCastExpr::checked_downcast")
        ar->sema_false(n->asserting_downcast, "TypeCastExpr::asserting_downcast")
        ar->sema_false(n->dynamic_only, "TypeCastExpr::dynamic_only")
        ar->sema_null<Decl>(n->enum_check, "TypeCastExpr::enum_check")
        ar->sema_false(n->base_adjust, "TypeCastExpr::base_adjust")
    }
}

/// Inserted by Sema at FFI call boundaries; no parsed tree has one. Its
/// types are Sema's, so a tree that reaches one fails in TypeIO.
fn io_implicit_boundary_cast_expr(ar: unsafe *ASTArchive,
                                  n:  unsafe *Expressions::ImplicitBoundaryCastExpr) {
    ar->expr<Expr>(&n->original)
    ar->type_<Type>(&n->source_type)
    ar->type_<Type>(&n->target_type)
}

fn io_paren_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::ParenExpr) {
    ar->expr<Expr>(&n->inner)
}

fn io_verbatim_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::VerbatimExpr) {
    ar->range(&n->span)
}

fn io_closure_expr(ar: unsafe *ASTArchive, n: unsafe *Expressions::ClosureExpr) {
    var count = ar->list<Expressions::ClosureExpr::Capture>(&n->captures)
    for var i: usize = 0; i < count; ++i {
        var unsafe *c = n->captures.get(i)
        ar->expr<NamedIdentExpr>(&c->name)
        ar->flag(&c->by_ptr)
        ar->flag(&c->is_const)
    }

    ar->decl_list<ParamDecl>(&n->params)
    ar->decl_list<GenericParamDecl>(&n->generic_params)
    ar->stmt<CompoundStmt>(&n->body_block)
    ar->expr<Expr>(&n->body_expr)
    ar->type_<Type>(&n->return_type)
    ar->en<FnBodyKind>(&n->body_kind)
    ar->en<FnModifier>(&n->modifiers)
    ar->type_list<Type>(&n->panic_set)
    ar->range(&n->panic_range)
    ar->range(&n->params_end)
    ar->flag(&n->is_variadic)
    ar->flag(&n->is_noreturn)
    ar->flag(&n->explicit_no_capture)
    ar->range(&n->capture_range)

    eval if defined!(DEBUG) {
        ar->sema_zero(n->panic_eff.size() as u64, "ClosureExpr::panic_eff")
        ar->sema_is(n->panic_state == PanicSetState::None, "ClosureExpr::panic_state")
        ar->sema_null<Type>(n->panic_result, "ClosureExpr::panic_result")
        // ClosureCaptures' resolution of the capture list.
        ar->sema_zero(n->cap_decls.size() as u64, "ClosureExpr::cap_decls")
        ar->sema_zero(n->cap_modes.size() as u64, "ClosureExpr::cap_modes")
        ar->sema_zero(n->cap_via_ptr.size() as u64, "ClosureExpr::cap_via_ptr")
        ar->sema_zero(n->cap_uses.size() as u64, "ClosureExpr::cap_uses")
        ar->sema_false(n->caps_resolved, "ClosureExpr::caps_resolved")
    }
}

/// The class an expression object is: its kind, or what a recovery node was
/// going to be.
fn expr_class(e: unsafe *Expr) -> ExprKind {
    if e->kind == ExprKind::RecoveryExpr {
        return e->recovery_kind
    }

    return e->kind
}

/// Writes or reads one expression: the family header, then its class.
pub fn expr_io(ar: unsafe *ASTArchive, e: unsafe *Expr) {
    io_expr_base(ar, e)
    io_expr_fields(ar, e)
}

/// The fields of an expression's own class, after its header.
fn io_expr_fields(ar: unsafe *ASTArchive, e: unsafe *Expr) {
    var cls = expr_class(e)

    match cls {
        case ExprKind::IntegerLiteralExpr {
            io_integer_literal_expr(ar, unsafe (e as unsafe *IntegerLiteralExpr))
        } case ExprKind::FloatingLiteralExpr {
            io_floating_literal_expr(ar, unsafe (e as unsafe *FloatingLiteralExpr))
        } case ExprKind::StringLiteralExpr {
            io_string_literal_expr(ar, unsafe (e as unsafe *StringLiteralExpr))
        } case ExprKind::CharacterLiteralExpr {
            io_character_literal_expr(ar, unsafe (e as unsafe *CharacterLiteralExpr))
        } case ExprKind::BooleanLiteralExpr {
            io_boolean_literal_expr(ar, unsafe (e as unsafe *BooleanLiteralExpr))
        } case ExprKind::NullLiteralExpr {
            io_null_literal_expr(ar, unsafe (e as unsafe *NullLiteralExpr))
        } case ExprKind::ListLiteralExpr {
            io_list_literal_expr(ar, unsafe (e as unsafe *Expressions::ListLiteralExpr))
        } case ExprKind::TupleLiteralExpr {
            io_tuple_literal_expr(ar, unsafe (e as unsafe *Expressions::TupleLiteralExpr))
        } case ExprKind::SetLiteralExpr {
            io_set_literal_expr(ar, unsafe (e as unsafe *Expressions::SetLiteralExpr))
        } case ExprKind::MapLiteralExpr {
            io_map_literal_expr(ar, unsafe (e as unsafe *Expressions::MapLiteralExpr))
        } case ExprKind::NamedInitializerExpr {
            io_named_initializer_expr(ar, unsafe (e as unsafe *Expressions::NamedInitializerExpr))
        } case ExprKind::AnonInitializerExpr {
            io_anon_initializer_expr(ar, unsafe (e as unsafe *Expressions::AnonInitializerExpr))
        } case ExprKind::ChainExpr {
            io_chain_expr(ar, unsafe (e as unsafe *ChainExpr))
        } case ExprKind::CallExpr {
            io_call_expr(ar, unsafe (e as unsafe *Expressions::CallExpr))
        } case ExprKind::SubscriptExpr {
            io_subscript_expr(ar, unsafe (e as unsafe *Expressions::SubscriptExpr))
        } case ExprKind::NamedIdentExpr {
            io_named_ident_expr(ar, unsafe (e as unsafe *NamedIdentExpr))
        } case ExprKind::UnaryOperatorExpr {
            io_unary_operator_expr(ar, unsafe (e as unsafe *Expressions::UnaryOperatorExpr))
        } case ExprKind::BinaryOperatorExpr {
            io_binary_operator_expr(ar, unsafe (e as unsafe *Expressions::BinaryOperatorExpr))
        } case ExprKind::AssignOperatorExpr {
            io_assign_operator_expr(ar, unsafe (e as unsafe *Expressions::AssignOperatorExpr))
        } case ExprKind::ImplConformanceExpr {
            io_impl_conformance_expr(ar, unsafe (e as unsafe *Expressions::ImplConformanceExpr))
        } case ExprKind::DerivesRelationExpr {
            io_derives_relation_expr(ar, unsafe (e as unsafe *Expressions::DerivesRelationExpr))
        } case ExprKind::IfExpr {
            io_if_expr(ar, unsafe (e as unsafe *Expressions::IfExpr))
        } case ExprKind::TryCatchExpr {
            io_try_catch_expr(ar, unsafe (e as unsafe *Expressions::TryCatchExpr))
        } case ExprKind::MatchExpr {
            io_match_expr(ar, unsafe (e as unsafe *Expressions::MatchExpr))
        } case ExprKind::RangeExpr {
            io_range_expr(ar, unsafe (e as unsafe *Expressions::RangeExpr))
        } case ExprKind::ClosureExpr {
            io_closure_expr(ar, unsafe (e as unsafe *Expressions::ClosureExpr))
        } case ExprKind::AwaitExpr {
            io_await_expr(ar, unsafe (e as unsafe *Expressions::AwaitExpr))
        } case ExprKind::SpawnExpr {
            io_spawn_expr(ar, unsafe (e as unsafe *Expressions::SpawnExpr))
        } case ExprKind::ThreadExpr {
            io_thread_expr(ar, unsafe (e as unsafe *Expressions::ThreadExpr))
        } case ExprKind::ConstraintExpr {
            io_constraint_expr(ar, unsafe (e as unsafe *Expressions::ConstraintExpr))
        } case ExprKind::SizeOfExpr {
            io_size_of_expr(ar, unsafe (e as unsafe *Expressions::SizeOfExpr))
        } case ExprKind::AlignOfExpr {
            io_align_of_expr(ar, unsafe (e as unsafe *Expressions::AlignOfExpr))
        } case ExprKind::TypeOfExpr {
            io_type_of_expr(ar, unsafe (e as unsafe *Expressions::TypeOfExpr))
        } case ExprKind::EvalExpr {
            io_eval_expr(ar, unsafe (e as unsafe *Expressions::EvalExpr))
        } case ExprKind::UnsafeExpr {
            io_unsafe_expr(ar, unsafe (e as unsafe *Expressions::UnsafeExpr))
        } case ExprKind::DeleteExpr {
            io_delete_expr(ar, unsafe (e as unsafe *Expressions::DeleteExpr))
        } case ExprKind::PackExpansionExpr {
            io_pack_expansion_expr(ar, unsafe (e as unsafe *Expressions::PackExpansionExpr))
        } case ExprKind::TypeCastExpr {
            io_type_cast_expr(ar, unsafe (e as unsafe *Expressions::TypeCastExpr))
        } case ExprKind::ImplicitBoundaryCastExpr {
            io_implicit_boundary_cast_expr(
                ar,
                unsafe (e as unsafe *Expressions::ImplicitBoundaryCastExpr),
            )
        } case ExprKind::ParenExpr {
            io_paren_expr(ar, unsafe (e as unsafe *Expressions::ParenExpr))
        } case ExprKind::VerbatimExpr {
            io_verbatim_expr(ar, unsafe (e as unsafe *Expressions::VerbatimExpr))
        } case ExprKind::NamedArgExpr {
            io_named_arg_expr(ar, unsafe (e as unsafe *Expressions::NamedArgExpr))
        } case ExprKind::InitListExpr {
            io_init_list_expr(ar, unsafe (e as unsafe *Expressions::InitListExpr))
        } case ExprKind::StmtExpr {
            io_stmt_expr(ar, unsafe (e as unsafe *Expressions::StmtExpr))
        } case ExprKind::UnwrapExpr {
            io_unwrap_expr(ar, unsafe (e as unsafe *Expressions::UnwrapExpr))
        } case ExprKind::DefinedExpr {
            io_defined_expr(ar, unsafe (e as unsafe *Expressions::DefinedExpr))
        } case ExprKind::AttributedExpr {
            io_attributed_expr(ar, unsafe (e as unsafe *Expressions::AttributedExpr))
        } case ExprKind::PanicOpExpr {
            io_panic_op_expr(ar, unsafe (e as unsafe *Expressions::PanicOpExpr))
        } case ExprKind::TypeTraitExpr {
            io_type_trait_expr(ar, unsafe (e as unsafe *Expressions::TypeTraitExpr))
        } case ExprKind::CxxNewExpr {
            io_cxx_new_expr(ar, unsafe (e as unsafe *Expressions::CxxNewExpr))
        } default {
            ar->fail("an expression a lowering minted (VariantInitExpr) is reachable from a parsed tree")
        }
    }
}
