/// --- The Kairo Project ------------- Compiler/ASTNode/Patterns.k ----- ///
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
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// --------------------------------------------------------------------- ///

import ASTNode::Base::*;
import AST::ASTContext::*;
import AST::Support::*;
import ASTNode::PrimaryExpressions::*;
import Source::SourceRange::*;
import Lexer::Token::*;

///  WildcardPattern :  _
class WildcardPattern derives Pattern {
    static fn create(ctx: *ASTContext, range: SourceRange) -> *WildcardPattern {
        var node   = ctx->alloc::<WildcardPattern>();
        node->kind  = PatternKind::WildcardPattern;
        node->range = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }
    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *WildcardPattern {
        var node            = ctx->alloc::<WildcardPattern>();
        node->kind          = PatternKind::RecoveryPattern;
        node->recovery_kind = PatternKind::WildcardPattern;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }
    /* OVERRIDE */ static fn classof(ptr: *Pattern) -> bool {
        return ptr->kind == PatternKind::WildcardPattern;
    }
    /* OVERRIDE */ static fn pattern_kind() -> PatternKind {
        return PatternKind::WildcardPattern;
    }
}

///  LiteralPattern :  1 | "foo" | true | null | 'a'
///  `value` is the literal expr (IntegerLiteralExpr, StringLiteralExpr, etc).
class LiteralPattern derives Pattern {
    pub var value: *Expr;

    static fn create(ctx: *ASTContext, range: SourceRange, value: *Expr) -> *LiteralPattern {
        var node   = ctx->alloc::<LiteralPattern>();
        node->kind  = PatternKind::LiteralPattern;
        node->range = range;
        node->value = value;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }
    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *LiteralPattern {
        var node            = ctx->alloc::<LiteralPattern>();
        node->kind          = PatternKind::RecoveryPattern;
        node->recovery_kind = PatternKind::LiteralPattern;
        node->range         = range;
        node->value         = &null;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }
    /* OVERRIDE */ static fn classof(ptr: *Pattern) -> bool {
        return ptr->kind == PatternKind::LiteralPattern;
    }
    /* OVERRIDE */ static fn pattern_kind() -> PatternKind {
        return PatternKind::LiteralPattern;
    }
}

///  BindingPattern :  var x | const x | var x: i32
///  Type-ascribed binding folds in here: type_ non-null when `: T` was written.
///  `is_const` is the resolved mutability. `name` is the bound identifier.
class BindingPattern derives Pattern {
    pub var name:     Token;
    pub var is_const: bool  = false;
    pub var type_:    *Type = &null;   ///< explicit `: T` ascription; null if none.

    static fn create(
        ctx:      *ASTContext,
        range:    SourceRange,
        name:     Token,
        is_const: bool,
        type_:    *Type
    ) -> *BindingPattern {
        var node      = ctx->alloc::<BindingPattern>();
        node->kind     = PatternKind::BindingPattern;
        node->range    = range;
        node->name     = name;
        node->is_const = is_const;
        node->type_    = type_;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }
    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *BindingPattern {
        var node            = ctx->alloc::<BindingPattern>();
        node->kind          = PatternKind::RecoveryPattern;
        node->recovery_kind = PatternKind::BindingPattern;
        node->range         = range;
        node->type_         = &null;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }
    /* OVERRIDE */ static fn classof(ptr: *Pattern) -> bool {
        return ptr->kind == PatternKind::BindingPattern;
    }
    /* OVERRIDE */ static fn pattern_kind() -> PatternKind {
        return PatternKind::BindingPattern;
    }
}

///  TupleDestructurePattern :  (p, p, ...)
class TupleDestructurePattern derives Pattern {
    pub var elements: FrozenList::<*Pattern>;

    static fn create(ctx: *ASTContext, range: SourceRange) -> *TupleDestructurePattern {
        var node   = ctx->alloc::<TupleDestructurePattern>();
        node->kind  = PatternKind::TupleDestructurePattern;
        node->range = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }
    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *TupleDestructurePattern {
        var node            = ctx->alloc::<TupleDestructurePattern>();
        node->kind          = PatternKind::RecoveryPattern;
        node->recovery_kind = PatternKind::TupleDestructurePattern;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }
    /* OVERRIDE */ static fn classof(ptr: *Pattern) -> bool {
        return ptr->kind == PatternKind::TupleDestructurePattern;
    }
    /* OVERRIDE */ static fn pattern_kind() -> PatternKind {
        return PatternKind::TupleDestructurePattern;
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
class ConstructorPattern derives Pattern {
    pub var head:        *Expr  = &null;          ///< resolved path (ChainExpr / NamedIdentExpr); null when is_dotted.
    pub var dotted_name: Token;                   ///< the `.Ident`; valid when is_dotted.
    pub var is_dotted:   bool   = false;
    pub var has_parens:  bool   = false;          ///< `Foo()` / `.V()` vs `Foo` / `.V`.
    pub var subpatterns: FrozenList::<*Pattern>;

    static fn create(
        ctx:        *ASTContext,
        range:      SourceRange,
        head:       *Expr,                        // <-- was *Type
        dotted:     Token,
        is_dotted:  bool,
        has_parens: bool
    ) -> *ConstructorPattern {
        var node        = ctx->alloc::<ConstructorPattern>();
        node->kind       = PatternKind::ConstructorPattern;
        node->range      = range;
        node->head       = head;
        node->dotted_name = dotted;
        node->is_dotted  = is_dotted;
        node->has_parens = has_parens;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ConstructorPattern {
        var node            = ctx->alloc::<ConstructorPattern>();
        node->kind          = PatternKind::RecoveryPattern;
        node->recovery_kind = PatternKind::ConstructorPattern;
        node->range         = range;
        node->head          = &null;
        node->is_dotted     = false;
        node->has_parens    = false;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Pattern) -> bool {
        return ptr->kind == PatternKind::ConstructorPattern;
    }
    /* OVERRIDE */ static fn pattern_kind() -> PatternKind {
        return PatternKind::ConstructorPattern;
    }
}

///  UnresolvedConstructorPattern :  Foo(p, ...) where Foo MISSED the lookup.
///
///  Identical shape to ConstructorPattern minus the dotted case (dotted never
///  misses). Distinct kind so sema runs one "resolve-or-error" path instead of
///  re-deriving hit vs miss. Never produced for `.Variant`.
class UnresolvedConstructorPattern derives Pattern {
    pub var head:        *Expr = &null;           ///< the unresolved path (ChainExpr / NamedIdentExpr).
    pub var has_parens:  bool  = false;
    pub var subpatterns: FrozenList::<*Pattern>;

    static fn create(
        ctx:        *ASTContext,
        range:      SourceRange,
        head:       *Expr,                        // <-- was *Type
        has_parens: bool
    ) -> *UnresolvedConstructorPattern {
        var node        = ctx->alloc::<UnresolvedConstructorPattern>();
        node->kind       = PatternKind::UnresolvedConstructorPattern;
        node->range      = range;
        node->head       = head;
        node->has_parens = has_parens;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *UnresolvedConstructorPattern {
        var node            = ctx->alloc::<UnresolvedConstructorPattern>();
        node->kind          = PatternKind::RecoveryPattern;
        node->recovery_kind = PatternKind::UnresolvedConstructorPattern;
        node->range         = range;
        node->head          = &null;
        node->has_parens    = false;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Pattern) -> bool {
        return ptr->kind == PatternKind::UnresolvedConstructorPattern;
    }
    /* OVERRIDE */ static fn pattern_kind() -> PatternKind {
        return PatternKind::UnresolvedConstructorPattern;
    }
}

///  AlternationPattern :  p | p | p   (NOT the top-level case comma; this is
///  the `|` or-pattern. The match parser builds the comma list into MatchCase
///  patterns; this node is for `|` inside a single pattern position once we
///  add it. Reserved now so sema and the printer have the kind.)
class AlternationPattern derives Pattern {
    pub var alternatives: FrozenList::<*Pattern>;

    static fn create(ctx: *ASTContext, range: SourceRange) -> *AlternationPattern {
        var node   = ctx->alloc::<AlternationPattern>();
        node->kind  = PatternKind::AlternationPattern;
        node->range = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }
    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *AlternationPattern {
        var node            = ctx->alloc::<AlternationPattern>();
        node->kind          = PatternKind::RecoveryPattern;
        node->recovery_kind = PatternKind::AlternationPattern;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }
    /* OVERRIDE */ static fn classof(ptr: *Pattern) -> bool {
        return ptr->kind == PatternKind::AlternationPattern;
    }
    /* OVERRIDE */ static fn pattern_kind() -> PatternKind {
        return PatternKind::AlternationPattern;
    }
}

///  RangePattern :  lo..hi | lo..=hi   bounds are *Expr (sema enforces const).
///  Either bound may be null for open ranges (..hi, lo..) if we allow them in
///  pattern position; parser fills what's present.
class RangePattern derives Pattern {
    pub var lo:           *Expr = &null;
    pub var hi:           *Expr = &null;
    pub var is_inclusive: bool  = false;   ///< `..=`

    static fn create(
        ctx:          *ASTContext,
        range:        SourceRange,
        lo:           *Expr,
        hi:           *Expr,
        is_inclusive: bool
    ) -> *RangePattern {
        var node          = ctx->alloc::<RangePattern>();
        node->kind         = PatternKind::RangePattern;
        node->range        = range;
        node->lo           = lo;
        node->hi           = hi;
        node->is_inclusive = is_inclusive;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }
    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *RangePattern {
        var node            = ctx->alloc::<RangePattern>();
        node->kind          = PatternKind::RecoveryPattern;
        node->recovery_kind = PatternKind::RangePattern;
        node->range         = range;
        node->lo            = &null;
        node->hi            = &null;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }
    /* OVERRIDE */ static fn classof(ptr: *Pattern) -> bool {
        return ptr->kind == PatternKind::RangePattern;
    }
    /* OVERRIDE */ static fn pattern_kind() -> PatternKind {
        return PatternKind::RangePattern;
    }
}

///  SlicePattern :  [p, p, ..rest] | [p, .., p] | [.., p]
///  `prefix` = patterns before the `..`, `suffix` = patterns after. `has_rest`
///  marks the `..`; `rest_binding` is the optional `..name` (null for bare `..`
///  or no rest). Without a rest, all elements live in `prefix` and suffix is
///  empty.
class SlicePattern derives Pattern {
    pub var prefix:       FrozenList::<*Pattern>;
    pub var suffix:       FrozenList::<*Pattern>;
    pub var has_rest:     bool  = false;
    pub var rest_binding: *Pattern = &null;   ///< BindingPattern for `..name`; null otherwise.

    static fn create(
        ctx:          *ASTContext,
        range:        SourceRange,
        has_rest:     bool,
        rest_binding: *Pattern
    ) -> *SlicePattern {
        var node          = ctx->alloc::<SlicePattern>();
        node->kind         = PatternKind::SlicePattern;
        node->range        = range;
        node->has_rest     = has_rest;
        node->rest_binding = rest_binding;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }
    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *SlicePattern {
        var node            = ctx->alloc::<SlicePattern>();
        node->kind          = PatternKind::RecoveryPattern;
        node->recovery_kind = PatternKind::SlicePattern;
        node->range         = range;
        node->has_rest      = false;
        node->rest_binding  = &null;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }
    /* OVERRIDE */ static fn classof(ptr: *Pattern) -> bool {
        return ptr->kind == PatternKind::SlicePattern;
    }
    /* OVERRIDE */ static fn pattern_kind() -> PatternKind {
        return PatternKind::SlicePattern;
    }
}