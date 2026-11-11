/// --- The Kairo Project -------------------- AST/Serialize/PatternIO.k --- ///
///
///   The Pattern family: one `io_` function per pattern class and the entry
///   points the archive's hooks call (pattern_alloc, pattern_io).
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

import AST::Kind::PatternKind::PatternKind
import AST::Node::Base::{
    Decl,
    Expr,
    Pattern,
    Type,
}
import AST::Node::Patterns
import AST::Serialize::Archive::ASTArchive
import AST::Serialize::NodeCommon::io_annotations

fn <T: type> new_pattern(ar: unsafe *ASTArchive) -> unsafe *Pattern {
    var unsafe *n = ar->ctx->alloc<T>()
    n->init_annotations(unsafe &ar->ctx->ast_alloc)
    return unsafe (n as unsafe *Pattern)
}

/// Reads a pattern's kind and allocates an object of its class.
pub fn pattern_alloc(ar: unsafe *ASTArchive) -> unsafe *Pattern {
    var kind = PatternKind::RecoveryPattern
    ar->en<PatternKind>(&kind)
    var cls = kind
    if kind == PatternKind::RecoveryPattern {
        ar->en<PatternKind>(&cls)
    }

    var p: unsafe *Pattern = &null
    match cls {
        case PatternKind::WildcardPattern {
            p = new_pattern<Patterns::WildcardPattern>(ar)
        } case PatternKind::LiteralPattern {
            p = new_pattern<Patterns::LiteralPattern>(ar)
        } case PatternKind::BindingPattern {
            p = new_pattern<Patterns::BindingPattern>(ar)
        } case PatternKind::TupleDestructurePattern {
            p = new_pattern<Patterns::TupleDestructurePattern>(ar)
        } case PatternKind::ConstructorPattern {
            p = new_pattern<Patterns::ConstructorPattern>(ar)
        } case PatternKind::UnresolvedConstructorPattern {
            p = new_pattern<Patterns::UnresolvedConstructorPattern>(ar)
        } case PatternKind::AlternationPattern {
            p = new_pattern<Patterns::AlternationPattern>(ar)
        } case PatternKind::RangePattern {
            p = new_pattern<Patterns::RangePattern>(ar)
        } case PatternKind::SlicePattern {
            p = new_pattern<Patterns::SlicePattern>(ar)
        } default {
            return &null
        }
    }

    p->kind = kind
    if kind == PatternKind::RecoveryPattern {
        p->recovery_kind = cls
    }

    return p
}

fn io_pattern_base(ar: unsafe *ASTArchive, p: unsafe *Pattern) {
    if !ar->reading {
        ar->en<PatternKind>(&p->kind)
        if p->kind == PatternKind::RecoveryPattern {
            ar->en<PatternKind>(&p->recovery_kind)
        }
    }

    ar->range(&p->range)
    ar->flag(&p->poisoned)
    io_annotations<Pattern>(ar, p)
    eval if defined!(DEBUG) {
        // What a pattern matches and names is PatternTyping's.
        ar->sema_null<Type>(p->type_, "Pattern::type_")
        ar->sema_null<Decl>(p->resolved_decl, "Pattern::resolved_decl")
        ar->sema_null<Decl>(p->field_decl, "Pattern::field_decl")
        ar->sema_is(p->pack_index == -1, "Pattern::pack_index")
        if p->kind != PatternKind::RecoveryPattern {
            ar->sema_is(p->recovery_kind == PatternKind::RecoveryPattern, "Pattern::recovery_kind")
        }
    }
}

fn io_literal_pattern(ar: unsafe *ASTArchive, n: unsafe *Patterns::LiteralPattern) {
    ar->expr<Expr>(&n->value)
}

fn io_binding_pattern(ar: unsafe *ASTArchive, n: unsafe *Patterns::BindingPattern) {
    ar->tok(&n->name)
    ar->flag(&n->is_const)
    ar->type_<Type>(&n->type_)
    // The parser's: the variable the name declares (Binding::decl).
    ar->decl<Decl>(&n->decl)
}

fn io_tuple_destructure_pattern(ar: unsafe *ASTArchive, n: unsafe *Patterns::TupleDestructurePattern) {
    ar->pattern_list<Pattern>(&n->elements)
}

fn io_constructor_pattern(ar: unsafe *ASTArchive, n: unsafe *Patterns::ConstructorPattern) {
    ar->expr<Expr>(&n->head)
    ar->tok(&n->dotted_name)
    ar->flag(&n->is_dotted)
    ar->flag(&n->has_parens)
    ar->pattern_list<Pattern>(&n->subpatterns)
}

fn io_unresolved_constructor_pattern(ar: unsafe *ASTArchive,
                                     n:  unsafe *Patterns::UnresolvedConstructorPattern) {
    ar->expr<Expr>(&n->head)
    ar->flag(&n->has_parens)
    ar->pattern_list<Pattern>(&n->subpatterns)
}

fn io_alternation_pattern(ar: unsafe *ASTArchive, n: unsafe *Patterns::AlternationPattern) {
    ar->pattern_list<Pattern>(&n->alternatives)
}

fn io_range_pattern(ar: unsafe *ASTArchive, n: unsafe *Patterns::RangePattern) {
    ar->expr<Expr>(&n->lo)
    ar->expr<Expr>(&n->hi)
    ar->flag(&n->is_inclusive)
}

fn io_slice_pattern(ar: unsafe *ASTArchive, n: unsafe *Patterns::SlicePattern) {
    ar->pattern_list<Pattern>(&n->prefix)
    ar->pattern_list<Pattern>(&n->suffix)
    ar->flag(&n->has_rest)
    ar->pattern<Pattern>(&n->rest_binding)
}

/// Writes or reads one pattern: the family header, then its class.
pub fn pattern_io(ar: unsafe *ASTArchive, p: unsafe *Pattern) {
    io_pattern_base(ar, p)

    var cls = p->kind
    if cls == PatternKind::RecoveryPattern {
        cls = p->recovery_kind
    }

    match cls {
        case PatternKind::WildcardPattern {
            // no fields of its own
        } case PatternKind::LiteralPattern {
            io_literal_pattern(ar, unsafe (p as unsafe *Patterns::LiteralPattern))
        } case PatternKind::BindingPattern {
            io_binding_pattern(ar, unsafe (p as unsafe *Patterns::BindingPattern))
        } case PatternKind::TupleDestructurePattern {
            io_tuple_destructure_pattern(ar, unsafe (p as unsafe *Patterns::TupleDestructurePattern))
        } case PatternKind::ConstructorPattern {
            io_constructor_pattern(ar, unsafe (p as unsafe *Patterns::ConstructorPattern))
        } case PatternKind::UnresolvedConstructorPattern {
            io_unresolved_constructor_pattern(
                ar,
                unsafe (p as unsafe *Patterns::UnresolvedConstructorPattern),
            )
        } case PatternKind::AlternationPattern {
            io_alternation_pattern(ar, unsafe (p as unsafe *Patterns::AlternationPattern))
        } case PatternKind::RangePattern {
            io_range_pattern(ar, unsafe (p as unsafe *Patterns::RangePattern))
        } case PatternKind::SlicePattern {
            io_slice_pattern(ar, unsafe (p as unsafe *Patterns::SlicePattern))
        } default {
            ar->fail("pattern of an unknown kind")
        }
    }
}
