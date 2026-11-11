/// --- The Kairo Project -------------------------- AST/Node/Patterns.k --- ///
///
///   Pattern-position AST nodes for `match` cases and destructuring.
///
///   Every concrete Pattern subclass sets kind to its PatternKind and provides
///   create / create_error plus classof / pattern_kind for the RTTI-free cast
///   system (see Casting.k).
///
///   NOTE: ASTContext::alloc does NOT run constructors. Every field is assigned
///         in create. FrozenList members are populated via from_buf(..., ctx)
///         even when empty (size 0).
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// --------------------------------------------------------------------- ///

import AST::ASTSupport::FrozenList
import AST::Context::ASTContext::ASTContext
import AST::Kind::PatternKind::PatternKind
import AST::Node::Base::{
    Decl,
    Expr,
    Pattern,
    Type,
}
import Location::SourceRange::SourceRange
import Token::Token::Token

///  WildcardPattern :  _
pub class WildcardPattern derives Pattern {
    pub static fn create(ctx: *ASTContext, range: SourceRange) -> unsafe *WildcardPattern {
        var unsafe *node = ctx->alloc<WildcardPattern>()
        node->kind  = PatternKind::WildcardPattern
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *WildcardPattern {
        var unsafe *node = ctx->alloc<WildcardPattern>()
        node->kind          = PatternKind::RecoveryPattern
        node->recovery_kind = PatternKind::WildcardPattern
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Pattern) -> bool {
        return ptr->kind == PatternKind::WildcardPattern
    }

    /* OVERRIDE */
    static fn pattern_kind() -> PatternKind {
        return PatternKind::WildcardPattern
    }
}

///  LiteralPattern :  1 | "foo" | true | null | 'a'
///  `value` is the literal expr (IntegerLiteralExpr, StringLiteralExpr, etc).
pub class LiteralPattern derives Pattern {
    pub var value: unsafe *Expr

    pub static fn create(ctx:   *ASTContext,
                         range: SourceRange,
                         value: unsafe *Expr) -> unsafe *LiteralPattern {
        var unsafe *node = ctx->alloc<LiteralPattern>()
        node->kind  = PatternKind::LiteralPattern
        node->range = range
        node->value = value
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *LiteralPattern {
        var unsafe *node = ctx->alloc<LiteralPattern>()
        node->kind          = PatternKind::RecoveryPattern
        node->recovery_kind = PatternKind::LiteralPattern
        node->range         = range
        node->value         = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Pattern) -> bool {
        return ptr->kind == PatternKind::LiteralPattern
    }

    /* OVERRIDE */
    static fn pattern_kind() -> PatternKind {
        return PatternKind::LiteralPattern
    }
}

///  BindingPattern :  var x | const x | var x: i32
///  Type-ascribed binding folds in here: type_ non-null when `: T` was written.
///  `is_const` is the resolved mutability. `name` is the bound identifier.
pub class BindingPattern derives Pattern {
    pub var name:     Token
    pub var is_const: bool         = false
    pub var type_:    unsafe *Type = &null ///< explicit `: T` ascription; null if none.

    /// The DECLARATION this pattern introduces (`case var n` declares `n`).
    /// Filled by PatternParse so the binder always has a Decl for uses in the
    /// arm body to bind to; see Statements.k Binding::decl for the rationale.
    /// Not in any symbol table (locals are excluded by design).
    pub var decl: unsafe *Decl = &null ///< always a VariableDecl; see Binding::decl.

    pub static fn create(ctx:      *ASTContext,
                         range:    SourceRange,
                         name:     Token,
                         is_const: bool,
                         type_:    unsafe *Type) -> unsafe *BindingPattern {
        var unsafe *node = ctx->alloc<BindingPattern>()
        node->kind     = PatternKind::BindingPattern
        node->range    = range
        node->name     = name
        node->is_const = is_const
        node->type_    = type_
        node->init_annotations(unsafe &ctx->ast_alloc)
        // `decl` is filled by PatternParse (which can see Declarations.k);
        // this file must not import it.
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *BindingPattern {
        var unsafe *node = ctx->alloc<BindingPattern>()
        node->kind          = PatternKind::RecoveryPattern
        node->recovery_kind = PatternKind::BindingPattern
        node->range         = range
        node->type_         = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Pattern) -> bool {
        return ptr->kind == PatternKind::BindingPattern
    }

    /* OVERRIDE */
    static fn pattern_kind() -> PatternKind {
        return PatternKind::BindingPattern
    }
}

///  TupleDestructurePattern :  (p, p, ...)
pub class TupleDestructurePattern derives Pattern {
    pub var elements: FrozenList<unsafe *Pattern>

    pub static fn create(ctx: *ASTContext, range: SourceRange) -> unsafe *TupleDestructurePattern {
        var unsafe *node = ctx->alloc<TupleDestructurePattern>()
        node->kind  = PatternKind::TupleDestructurePattern
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx:   *ASTContext,
                               range: SourceRange) -> unsafe *TupleDestructurePattern {
        var unsafe *node = ctx->alloc<TupleDestructurePattern>()
        node->kind          = PatternKind::RecoveryPattern
        node->recovery_kind = PatternKind::TupleDestructurePattern
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Pattern) -> bool {
        return ptr->kind == PatternKind::TupleDestructurePattern
    }

    /* OVERRIDE */
    static fn pattern_kind() -> PatternKind {
        return PatternKind::TupleDestructurePattern
    }
}

///  ConstructorPattern :  Foo(p, ...) | Foo<T>(p, ...) | Kind::V(p, ...)
///                      | .Variant(p, ...) | .Variant
///
///  RESOLVED path head (hoisted hit), OR the dotted form (always a variant,
///  needs no lookup). `head` is the parsed type path (*Type / ChainType) for
///  the non-dotted form; null for the dotted form, where `dotted_name` carries
///  the `.Ident`. `is_dotted` selects between them. `subpatterns` is the paren
///  payload, empty for a bare `.Variant` or `Foo` with no parens.
///  `has_parens` distinguishes `Foo` (nullary path pattern) from `Foo()`.
pub class ConstructorPattern derives Pattern {
    pub var head:        unsafe *Expr                = &null ///< resolved path (ChainExpr / NamedIdentExpr); null when is_dotted.
    pub var dotted_name: Token ///< the `.Ident`; valid when is_dotted.
    pub var is_dotted:   bool                        = false
    pub var has_parens:  bool                        = false ///< `Foo()` / `.V()` vs `Foo` / `.V`.
    pub var subpatterns: FrozenList<unsafe *Pattern>

    pub static fn create(
        ctx:        *ASTContext,
        range:      SourceRange,
        head:       unsafe *Expr,                        // <-- was *Type
        dotted:     Token,
        is_dotted:  bool,
        has_parens: bool
    ) -> unsafe *ConstructorPattern {
        var unsafe *node = ctx->alloc<ConstructorPattern>()
        node->kind        = PatternKind::ConstructorPattern
        node->range       = range
        node->head        = head
        node->dotted_name = dotted
        node->is_dotted   = is_dotted
        node->has_parens  = has_parens
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    pub static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *ConstructorPattern {
        var unsafe *node = ctx->alloc<ConstructorPattern>()
        node->kind          = PatternKind::RecoveryPattern
        node->recovery_kind = PatternKind::ConstructorPattern
        node->range         = range
        node->head          = &null
        node->is_dotted     = false
        node->has_parens    = false
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Pattern) -> bool {
        return ptr->kind == PatternKind::ConstructorPattern
    }

    /* OVERRIDE */
    static fn pattern_kind() -> PatternKind {
        return PatternKind::ConstructorPattern
    }
}

///  UnresolvedConstructorPattern :  Foo(p, ...) where Foo MISSED the lookup.
///
///  Identical shape to ConstructorPattern minus the dotted case (dotted never
///  misses). Distinct kind so sema runs one "resolve-or-error" path instead of
///  re-deriving hit vs miss. Never produced for `.Variant`.
pub class UnresolvedConstructorPattern derives Pattern {
    pub var head:        unsafe *Expr                = &null ///< the unresolved path (ChainExpr / NamedIdentExpr).
    pub var has_parens:  bool                        = false
    pub var subpatterns: FrozenList<unsafe *Pattern>

    pub static fn create(
        ctx:        *ASTContext,
        range:      SourceRange,
        head:       unsafe *Expr,                        // <-- was *Type
        has_parens: bool
    ) -> unsafe *UnresolvedConstructorPattern {
        var unsafe *node = ctx->alloc<UnresolvedConstructorPattern>()
        node->kind       = PatternKind::UnresolvedConstructorPattern
        node->range      = range
        node->head       = head
        node->has_parens = has_parens
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx:   *ASTContext,
                           range: SourceRange) -> unsafe *UnresolvedConstructorPattern {
        var unsafe *node = ctx->alloc<UnresolvedConstructorPattern>()
        node->kind          = PatternKind::RecoveryPattern
        node->recovery_kind = PatternKind::UnresolvedConstructorPattern
        node->range         = range
        node->head          = &null
        node->has_parens    = false
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Pattern) -> bool {
        return ptr->kind == PatternKind::UnresolvedConstructorPattern
    }

    /* OVERRIDE */
    static fn pattern_kind() -> PatternKind {
        return PatternKind::UnresolvedConstructorPattern
    }
}

///  AlternationPattern :  p | p | p   (NOT the top-level case comma; this is
///  the `|` or-pattern. The match parser builds the comma list into MatchCase
///  patterns; this node is for `|` inside a single pattern position.
///  Reserved so sema and the printer have the kind.)
pub class AlternationPattern derives Pattern {
    pub var alternatives: FrozenList<unsafe *Pattern>

    static fn create(ctx: *ASTContext, range: SourceRange) -> unsafe *AlternationPattern {
        var unsafe *node = ctx->alloc<AlternationPattern>()
        node->kind  = PatternKind::AlternationPattern
        node->range = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *AlternationPattern {
        var unsafe *node = ctx->alloc<AlternationPattern>()
        node->kind          = PatternKind::RecoveryPattern
        node->recovery_kind = PatternKind::AlternationPattern
        node->range         = range
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Pattern) -> bool {
        return ptr->kind == PatternKind::AlternationPattern
    }

    /* OVERRIDE */
    static fn pattern_kind() -> PatternKind {
        return PatternKind::AlternationPattern
    }
}

///  RangePattern :  lo..hi | lo..=hi   bounds are *Expr (sema enforces const).
///  Either bound may be null for open ranges (..hi, lo..) in
///  pattern position; parser fills what's present.
pub class RangePattern derives Pattern {
    pub var lo:           unsafe *Expr = &null
    pub var hi:           unsafe *Expr = &null
    pub var is_inclusive: bool         = false ///< `..=`

    pub static fn create(ctx:          *ASTContext,
                         range:        SourceRange,
                         lo:           unsafe *Expr,
                         hi:           unsafe *Expr,
                         is_inclusive: bool) -> unsafe *RangePattern {
        var unsafe *node = ctx->alloc<RangePattern>()
        node->kind         = PatternKind::RangePattern
        node->range        = range
        node->lo           = lo
        node->hi           = hi
        node->is_inclusive = is_inclusive
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *RangePattern {
        var unsafe *node = ctx->alloc<RangePattern>()
        node->kind          = PatternKind::RecoveryPattern
        node->recovery_kind = PatternKind::RangePattern
        node->range         = range
        node->lo            = &null
        node->hi            = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Pattern) -> bool {
        return ptr->kind == PatternKind::RangePattern
    }

    /* OVERRIDE */
    static fn pattern_kind() -> PatternKind {
        return PatternKind::RangePattern
    }
}

///  SlicePattern :  [p, p, ..rest] | [p, .., p] | [.., p]
///  `prefix` = patterns before the `..`, `suffix` = patterns after. `has_rest`
///  marks the `..`; `rest_binding` is the optional `..name` (null for bare `..`
///  or no rest). Without a rest, all elements live in `prefix` and suffix is
///  empty.
pub class SlicePattern derives Pattern {
    pub var prefix:       FrozenList<unsafe *Pattern>
    pub var suffix:       FrozenList<unsafe *Pattern>
    pub var has_rest:     bool                        = false
    pub var rest_binding: unsafe *Pattern             = &null ///< BindingPattern for `..name`; null otherwise.

    pub static fn create(ctx:          *ASTContext,
                         range:        SourceRange,
                         has_rest:     bool,
                         rest_binding: unsafe *Pattern) -> unsafe *SlicePattern {
        var unsafe *node = ctx->alloc<SlicePattern>()
        node->kind         = PatternKind::SlicePattern
        node->range        = range
        node->has_rest     = has_rest
        node->rest_binding = rest_binding
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> unsafe *SlicePattern {
        var unsafe *node = ctx->alloc<SlicePattern>()
        node->kind          = PatternKind::RecoveryPattern
        node->recovery_kind = PatternKind::SlicePattern
        node->range         = range
        node->has_rest      = false
        node->rest_binding  = &null
        node->init_annotations(unsafe &ctx->ast_alloc)
        return node
    }

    /* OVERRIDE */
    static fn classof(ptr: *const Pattern) -> bool {
        return ptr->kind == PatternKind::SlicePattern
    }

    /* OVERRIDE */
    static fn pattern_kind() -> PatternKind {
        return PatternKind::SlicePattern
    }
}
