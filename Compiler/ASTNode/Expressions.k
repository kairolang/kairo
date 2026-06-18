/// --- The Kairo Project ----------------------------------- <filename> --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
/// \invariant Recovery node casting contract:
///
/// When kind == ExprKind::RecoveryExpr and recovery_kind == ExprKind::X,
/// the node was allocated as X and it is ALWAYS safe to cast:
///
///   static_cast<X*>(recovery_expr_ptr)
///
/// This is guaranteed by create_error() on every concrete node class.
/// Sema relies on this invariant for partial recovery type checking.
/// Codegen relies on this to emit defaults for broken nodes.
///
/// DO NOT allocate a bare Expr and set recovery_kindthe cast will
/// read out of bounds. Always use the concrete node's create_error().
///
import ASTNode::Base::*;
import ASTNode::Casting::*;
import ASTNode::PrimaryExpressions::*;
import ASTNode::Types::*;
import AST::ASTContext::*;
import AST::Support::*;

///
///  CallExpr
///  expr(args) function call, method call, constructor call.
///  Callee is any expression. Separate from ChainExpr so sema can resolve
///  the callee expression independently from overload resolution on the args.
///
///  examples:
///    foo(x, y)                callee=NamedIdentExpr("foo")
///    foo.bar(x)               callee=ChainExpr(foo.bar)
///    foo::bar::<T>(x)         callee=ChainExpr(foo::bar::<T>)
///    (get_fn())(x)            callee=CallExpr(get_fn, [])
///    arr[0](x)                callee=SubscriptExpr(arr, 0)
///
class CallExpr derives Expr {
    /// the expression being called.
    pub var callee: *Expr;

    /// the argument list. empty for no-arg calls like `foo()`.
    pub var args:   FrozenList::<*Expr>;

    static fn create(
        ctx:    *ASTContext,
        range:  SourceRange,
        callee: *Expr
    ) -> *CallExpr {
        var node     = ctx->alloc::<CallExpr>();
        node->kind   = ExprKind::CallExpr;
        node->range  = range;
        node->callee = callee;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *CallExpr {
        var node            = ctx->alloc::<CallExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::CallExpr;
        node->range         = range;
        node->callee        = &null;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::CallExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::CallExpr;
    }

    fn arg_count(self) -> usize {
        return self.args.size();
    }
}

///
///  SubscriptExpr
///  expr[index] element access or slice.
///  For slices, index is a RangeExpr (e.g. arr[1..3]).
///
///  examples:
///    arr[0]       element access
///    arr[1..3]    slice (index is RangeExpr)
///    arr[..3]     slice from start
///    mat[i][j]    nested: base is another SubscriptExpr
///
class SubscriptExpr derives Expr {
    /// the expression being indexed.
    pub var base:  *Expr;

    /// the index or range expression inside the brackets.
    pub var index: *Expr;

    static fn create(
        ctx:   *ASTContext,
        range: SourceRange,
        base:  *Expr,
        index: *Expr
    ) -> *SubscriptExpr {
        var node    = ctx->alloc::<SubscriptExpr>();
        node->kind  = ExprKind::SubscriptExpr;
        node->range = range;
        node->base  = base;
        node->index = index;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *SubscriptExpr {
        var node            = ctx->alloc::<SubscriptExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::SubscriptExpr;
        node->range         = range;
        node->base          = &null;
        node->index         = &null;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::SubscriptExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::SubscriptExpr;
    }
}

///
///  ListLiteralExpr
///  [1, 2, 3]
///
class ListLiteralExpr derives Expr {
    pub var elements: FrozenList::<*Expr>;

    static fn create(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *ListLiteralExpr {
        var node    = ctx->alloc::<ListLiteralExpr>();
        node->kind  = ExprKind::ListLiteralExpr;
        node->range = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *ListLiteralExpr {
        var node            = ctx->alloc::<ListLiteralExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::ListLiteralExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::ListLiteralExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::ListLiteralExpr;
    }
}

///
///  TupleLiteralExpr
///  (1, "two", 3.0)
///
class TupleLiteralExpr derives Expr {
    pub var elements: FrozenList::<*Expr>;

    static fn create(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *TupleLiteralExpr {
        var node    = ctx->alloc::<TupleLiteralExpr>();
        node->kind  = ExprKind::TupleLiteralExpr;
        node->range = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *TupleLiteralExpr {
        var node            = ctx->alloc::<TupleLiteralExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::TupleLiteralExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::TupleLiteralExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::TupleLiteralExpr;
    }
}

///
///  SetLiteralExpr
///  {1, 2, 3}
///
class SetLiteralExpr derives Expr {
    pub var elements: FrozenList::<*Expr>;

    static fn create(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *SetLiteralExpr {
        var node    = ctx->alloc::<SetLiteralExpr>();
        node->kind  = ExprKind::SetLiteralExpr;
        node->range = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *SetLiteralExpr {
        var node            = ctx->alloc::<SetLiteralExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::SetLiteralExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::SetLiteralExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::SetLiteralExpr;
    }
}

///
///  MapLiteralExpr
///  {"key": value, "other": value2}
///
class MapLiteralExpr derives Expr {
    struct Entry {
        var key:   *Expr;
        var value: *Expr;
        var range: SourceRange;
    }

    pub var entries: FrozenList::<Entry>;

    static fn create(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *MapLiteralExpr {
        var node    = ctx->alloc::<MapLiteralExpr>();
        node->kind  = ExprKind::MapLiteralExpr;
        node->range = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *MapLiteralExpr {
        var node            = ctx->alloc::<MapLiteralExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::MapLiteralExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::MapLiteralExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::MapLiteralExpr;
    }
}

struct InitField {
    var name:   Token;       ///< field name token
    var value: *Expr;        ///< initializer expression
    var range:  SourceRange; ///< range covering `name: value`
}

///
///  NamedInitializerExpr
///  Point { x: 1, y: 2 }
///
class NamedInitializerExpr derives Expr {
    /// the type being initialized. ChainExpr or NamedIdentExpr.
    pub var type_expr: *Expr;
    pub var ctx: *ASTContext;
    /// field initializers in source order.
    pub var fields:    FrozenList::<InitField>;

    static fn create(
        ctx:       *ASTContext,
        range:     SourceRange,
        type_expr: *Expr
    ) -> *NamedInitializerExpr {
        var node        = ctx->alloc::<NamedInitializerExpr>();
        node->kind      = ExprKind::NamedInitializerExpr;
        node->range     = range;
        node->type_expr = type_expr;
        node->ctx       = ctx;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *NamedInitializerExpr {
        var node            = ctx->alloc::<NamedInitializerExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::NamedInitializerExpr;
        node->range         = range;
        node->type_expr     = &null;
        node->ctx           = ctx;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::NamedInitializerExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::NamedInitializerExpr;
    }
}

///
///  AnonInitializerExpr
///  { .x: 1, .y: 2 }
///  Sema infers the type from context (assignment target, return type, etc.).
///
class AnonInitializerExpr derives Expr {
    pub var fields: FrozenList::<InitField>;
    pub var ctx: *ASTContext;

    static fn create(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *AnonInitializerExpr {
        var node    = ctx->alloc::<AnonInitializerExpr>();
        node->kind  = ExprKind::AnonInitializerExpr;
        node->range = range;
        node->ctx   = ctx;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *AnonInitializerExpr {
        var node            = ctx->alloc::<AnonInitializerExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::AnonInitializerExpr;
        node->range         = range;
        node->ctx           = ctx;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::AnonInitializerExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::AnonInitializerExpr;
    }
}

///
///  UnaryOperatorExpr
///  prefix:  !x  -x  ~x  &x  *x  ++x  --x
///  postfix: x++  x--  x...
///
class UnaryOperatorExpr derives Expr {
    enum Fix derives u8 {
        Prefix,
        Postfix,
    }

    pub var operand:  *Expr;
    pub var op_token: Token;  ///< the operator token (!, -, *, &, ++, --, etc.)
    pub var fix:      Fix;

    static fn create(
        ctx:      *ASTContext,
        range:    SourceRange,
        operand:  *Expr,
        op_token: Token,
        fix:      Fix
    ) -> *UnaryOperatorExpr {
        var node       = ctx->alloc::<UnaryOperatorExpr>();
        node->kind     = ExprKind::UnaryOperatorExpr;
        node->range    = range;
        node->operand  = operand;
        node->op_token = op_token;
        node->fix      = fix;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *UnaryOperatorExpr {
        var node            = ctx->alloc::<UnaryOperatorExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::UnaryOperatorExpr;
        node->range         = range;
        node->operand       = &null;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::UnaryOperatorExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::UnaryOperatorExpr;
    }

    fn is_prefix(self) -> bool  { return self.fix == Fix::Prefix; }
    fn is_postfix(self) -> bool { return self.fix == Fix::Postfix; }
}

///
///  BinaryOperatorExpr
///  x + y | x && y | x == y | x << y | x ** y | etc.
///
class BinaryOperatorExpr derives Expr {
    pub var lhs:      *Expr;
    pub var rhs:      *Expr;
    pub var op_token: Token;

    static fn create(
        ctx:      *ASTContext,
        range:    SourceRange,
        lhs:      *Expr,
        rhs:      *Expr,
        op_token: Token
    ) -> *BinaryOperatorExpr {
        var node       = ctx->alloc::<BinaryOperatorExpr>();
        node->kind     = ExprKind::BinaryOperatorExpr;
        node->range    = range;
        node->lhs      = lhs;
        node->rhs      = rhs;
        node->op_token = op_token;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *BinaryOperatorExpr {
        var node            = ctx->alloc::<BinaryOperatorExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::BinaryOperatorExpr;
        node->range         = range;
        node->lhs           = &null;
        node->rhs           = &null;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::BinaryOperatorExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::BinaryOperatorExpr;
    }
}

///
///  AssignOperatorExpr
///  x = y | x += y | x -= y | x **= y | etc.
///  Right-associative. Distinct from BinaryOperatorExpr for visitor dispatch.
///
class AssignOperatorExpr derives Expr {
    pub var lhs:      *Expr;
    pub var rhs:      *Expr;
    pub var op_token: Token;

    static fn create(
        ctx:      *ASTContext,
        range:    SourceRange,
        lhs:      *Expr,
        rhs:      *Expr,
        op_token: Token
    ) -> *AssignOperatorExpr {
        var node       = ctx->alloc::<AssignOperatorExpr>();
        node->kind     = ExprKind::AssignOperatorExpr;
        node->range    = range;
        node->lhs      = lhs;
        node->rhs      = rhs;
        node->op_token = op_token;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(
        ctx:   *ASTContext,
        range: SourceRange
    ) -> *AssignOperatorExpr {
        var node            = ctx->alloc::<AssignOperatorExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::AssignOperatorExpr;
        node->range         = range;
        node->lhs           = &null;
        node->rhs           = &null;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::AssignOperatorExpr;
    }

    static fn expr_kind() -> ExprKind {
        return ExprKind::AssignOperatorExpr;
    }
}

///
///  ImplConformanceExpr
///  T impl Interface produces bool.
///
class ImplConformanceExpr derives Expr {
    pub var subject:   *Type; ///< the type being tested.
    pub var inter:     *Type; ///< the inter being checked.

    static fn create(
        ctx:       *ASTContext,
        range:     SourceRange,
        subject:   *Type,
        inter: *Type
    ) -> *ImplConformanceExpr {
        var node        = ctx->alloc::<ImplConformanceExpr>();
        node->kind      = ExprKind::ImplConformanceExpr;
        node->range     = range;
        node->subject   = subject;
        node->inter     = inter;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ImplConformanceExpr {
        var node            = ctx->alloc::<ImplConformanceExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::ImplConformanceExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool { return ptr->kind == ExprKind::ImplConformanceExpr; }
    static fn expr_kind() -> ExprKind { return ExprKind::ImplConformanceExpr; }
}

///
///  DerivesRelationExpr
///  T derives Base produces bool.
///
class DerivesRelationExpr derives Expr {
    pub var subject: *Type;
    pub var base:    *Type;

    static fn create(
        ctx:     *ASTContext,
        range:   SourceRange,
        subject: *Type,
        base:    *Type
    ) -> *DerivesRelationExpr {
        var node      = ctx->alloc::<DerivesRelationExpr>();
        node->kind    = ExprKind::DerivesRelationExpr;
        node->range   = range;
        node->subject = subject;
        node->base    = base;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *DerivesRelationExpr {
        var node            = ctx->alloc::<DerivesRelationExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::DerivesRelationExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool { return ptr->kind == ExprKind::DerivesRelationExpr; }
    static fn expr_kind() -> ExprKind { return ExprKind::DerivesRelationExpr; }
}

///
///  IfExpr
///  Grammar:  'if' expr '{' expr '}'
///            ('else' 'if' expr '{' expr '}')*
///            'else' '{' expr '}'
///
///  Expression-form conditional. Each branch is a SINGLE expression that is the
///  branch's value (Kairo has no implicit tail-return; statement bodies use
///  ConditionalStmt instead). The final `else` is MANDATORY and parser-enforced:
///  an expression must yield a value on every path.
///
///  Flat representation (no nested IfExpr): the primary arm is
///  `condition`/`then_expr`; zero or more `else if` arms live in `else_ifs`;
///  the trailing `else` value is `else_expr`. Sema walks `else_ifs` in order.
///
class IfExpr derives Expr {
    struct ElseIf {
        var condition: *Expr;       ///< the `else if` guard.
        var body:      *Expr;       ///< single-expression value for this arm.
        var range:     SourceRange;
    }

    pub var condition: *Expr;
    pub var then_expr: *Expr;
    pub var else_ifs:  FrozenList::<ElseIf>; ///< zero or more `else if` arms, in order.
    pub var else_expr: *Expr;                ///< mandatory final else value.

    static fn create(
        ctx:       *ASTContext,
        range:     SourceRange,
        condition: *Expr,
        then_expr: *Expr,
        else_expr: *Expr
    ) -> *IfExpr {
        var node        = ctx->alloc::<IfExpr>();
        node->kind      = ExprKind::IfExpr;
        node->range     = range;
        node->annotations.set_allocator(&(ctx->nodes));
        node->condition = condition;
        node->then_expr = then_expr;
        node->else_expr = else_expr;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *IfExpr {
        var node            = ctx->alloc::<IfExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::IfExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::IfExpr;
    }
    /* OVERRIDE */ static fn expr_kind() -> ExprKind {
        return ExprKind::IfExpr;
    }
}

///
///  TryCatchExpr
///  Grammar:  'try' '{' expr '}'
///            ('catch' ('var'|'const')? identifier ':' type '{' expr '}')*
///            ('catch' ('var'|'const')? identifier? '{' expr '}')?
///
///  Expression-form try/catch. The try body and every catch body is a SINGLE
///  expression (the value of that path). At least one catch arm is required
///  (parser-enforced). Catch arms split into:
///    - typed:   `catch e: Error { v }`          (filter != null)
///    - default: `catch { v }` / `catch e { v }` (filter == null)
///  A default arm is terminal: nothing may follow it (parser-enforced, which
///  also rejects multiple defaults). Exhaustiveness is a sema concern.
///
///  Binding mutability follows the usual rule: bare `e` is mutable, `const e`
///  is immutable, `var e` is the explicit mutable form. `has_binding` is false
///  only for the bare `catch { }` default.
///
class TryCatchExpr derives Expr {
    struct CatchArm {
        var has_binding: bool;            ///< false for bare `catch { }`.
        var is_const:    bool;            ///< `const e`; false for `e` / `var e`.
        var binding:     *NamedIdentExpr; ///< null when !has_binding.
        var filter:      *Type;           ///< null for a default (untyped) arm.
        var body:        *Expr;           ///< single-expression branch value.
        var range:       SourceRange;
    }

    pub var try_expr:   *Expr;
    pub var catch_arms: FrozenList::<CatchArm>;

    static fn create(ctx: *ASTContext, range: SourceRange, try_expr: *Expr) -> *TryCatchExpr {
        var node       = ctx->alloc::<TryCatchExpr>();
        node->kind     = ExprKind::TryCatchExpr;
        node->range    = range;
        node->annotations.set_allocator(&(ctx->nodes));
        node->try_expr = try_expr;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *TryCatchExpr {
        var node            = ctx->alloc::<TryCatchExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::TryCatchExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::TryCatchExpr;
    }
    /* OVERRIDE */ static fn expr_kind() -> ExprKind {
        return ExprKind::TryCatchExpr;
    }
}

///  MatchExpr :  match scrutinee { (case pattern.. (where guard)? { expr })+ }
///
///  Expression-form match. Each case yields a single value expression (held in
///  MatchCase.expression; body stays null in expr form). Exhaustiveness is a
///  sema concern. The scrutinee is the matched operand.
class MatchExpr derives Expr {
    pub var scrutinee: *Expr = &null;
    pub var cases:     FrozenList::<MatchCase>;

    static fn create(ctx: *ASTContext, range: SourceRange, scrutinee: *Expr) -> *MatchExpr {
        var node        = ctx->alloc::<MatchExpr>();
        node->kind       = ExprKind::MatchExpr;
        node->range      = range;
        node->scrutinee  = scrutinee;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *MatchExpr {
        var node            = ctx->alloc::<MatchExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::MatchExpr;
        node->range         = range;
        node->scrutinee     = &null;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Expr) -> bool {
        return ptr->kind == ExprKind::MatchExpr;
    }
    /* OVERRIDE */ static fn expr_kind() -> ExprKind {
        return ExprKind::MatchExpr;
    }
}

///
///  RangeExpr
///  x..y | x..=y | ..y | x.. | ..
///
class RangeExpr derives Expr {
    pub var begin:        *Expr; ///< null for `..y` or `..`
    pub var end:          *Expr; ///< null for `x..` or `..`
    pub var is_inclusive: bool;  ///< true for `..=`

    static fn create(
        ctx:          *ASTContext,
        range:        SourceRange,
        begin:        *Expr,
        end:          *Expr,
        is_inclusive: bool
    ) -> *RangeExpr {
        var node          = ctx->alloc::<RangeExpr>();
        node->kind        = ExprKind::RangeExpr;
        node->range       = range;
        node->begin       = begin;
        node->end         = end;
        node->is_inclusive = is_inclusive;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *RangeExpr {
        var node            = ctx->alloc::<RangeExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::RangeExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool { return ptr->kind == ExprKind::RangeExpr; }
    static fn expr_kind() -> ExprKind { return ExprKind::RangeExpr; }
}

///
///  ClosureExpr
///  fn <T> (x: T, y: i32)|captured| -> i32 { x + y + captured }
///  fn (x: i32) { std::print(x) }
///
///  params, generics, captures, return type, and body are all parsed by
///  DeclParse since they share structure with function declarations.
///  The body is a *Stmt (block statement) or *Expr (single expression).
///
class ClosureExpr derives Expr {

    struct Capture {
        var name:  *NamedIdentExpr; ///< the captured variable's name token.
        var by_ref: bool;             ///< true if `|&captured|`, false if `|captured|`.
    }
    pub var body:        *Expr;  ///< single-expression body or block.
    pub var params:      FrozenList::<*ParamDecl>;
    pub var modifiers:   FnModifier = FnModifier::None;
    pub var return_type: *Type;  ///< null if inferred.
    pub var is_variadic: bool = false;          ///< trailing `...name: T` pack param.
    pub var is_noreturn: bool = false;   
    pub var captures:    FrozenList::<Capture>; ///< captured variables, in source order.
    // params and generics stored as FrozenLists once DeclParse defines ParamDecl.

    static fn create(
        ctx:   *ASTContext,
        range: SourceRange,
        body:  *Expr
    ) -> *ClosureExpr {
        var node    = ctx->alloc::<ClosureExpr>();
        node->kind  = ExprKind::ClosureExpr;
        node->range = range;
        node->body  = body;
        
        node->return_type = &null;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ClosureExpr {
        var node            = ctx->alloc::<ClosureExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::ClosureExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool { return ptr->kind == ExprKind::ClosureExpr; }
    static fn expr_kind() -> ExprKind { return ExprKind::ClosureExpr; }
}

///
///  AwaitExpr
///  await expr
///
class AwaitExpr derives Expr {
    pub var operand: *Expr;

    static fn create(ctx: *ASTContext, range: SourceRange, operand: *Expr) -> *AwaitExpr {
        var node      = ctx->alloc::<AwaitExpr>();
        node->kind    = ExprKind::AwaitExpr;
        node->range   = range;
        node->operand = operand;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *AwaitExpr {
        var node            = ctx->alloc::<AwaitExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::AwaitExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool { return ptr->kind == ExprKind::AwaitExpr; }
    static fn expr_kind() -> ExprKind { return ExprKind::AwaitExpr; }
}

///
///  SpawnExpr
///  spawn expr
///
class SpawnExpr derives Expr {
    pub var operand: *Expr;

    static fn create(ctx: *ASTContext, range: SourceRange, operand: *Expr) -> *SpawnExpr {
        var node      = ctx->alloc::<SpawnExpr>();
        node->kind    = ExprKind::SpawnExpr;
        node->range   = range;
        node->operand = operand;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *SpawnExpr {
        var node            = ctx->alloc::<SpawnExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::SpawnExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool { return ptr->kind == ExprKind::SpawnExpr; }
    static fn expr_kind() -> ExprKind { return ExprKind::SpawnExpr; }
}

///
///  ThreadExpr
///  thread expr
///
class ThreadExpr derives Expr {
    pub var operand: *Expr;

    static fn create(ctx: *ASTContext, range: SourceRange, operand: *Expr) -> *ThreadExpr {
        var node      = ctx->alloc::<ThreadExpr>();
        node->kind    = ExprKind::ThreadExpr;
        node->range   = range;
        node->operand = operand;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ThreadExpr {
        var node            = ctx->alloc::<ThreadExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::ThreadExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool { return ptr->kind == ExprKind::ThreadExpr; }
    static fn expr_kind() -> ExprKind { return ExprKind::ThreadExpr; }
}

///
///  SizeOfExpr
///  sizeof T | sizeof(T)
///
class SizeOfExpr derives Expr {
    pub var type_arg: *Type;

    static fn create(ctx: *ASTContext, range: SourceRange, type_arg: *Type) -> *SizeOfExpr {
        var node       = ctx->alloc::<SizeOfExpr>();
        node->kind     = ExprKind::SizeOfExpr;
        node->range    = range;
        node->type_arg = type_arg;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *SizeOfExpr {
        var node            = ctx->alloc::<SizeOfExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::SizeOfExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool { return ptr->kind == ExprKind::SizeOfExpr; }
    static fn expr_kind() -> ExprKind { return ExprKind::SizeOfExpr; }
}

///
///  AlignOfExpr
///  alignof T | alignof(T)
///
class AlignOfExpr derives Expr {
    pub var type_arg: *Type;

    static fn create(ctx: *ASTContext, range: SourceRange, type_arg: *Type) -> *AlignOfExpr {
        var node       = ctx->alloc::<AlignOfExpr>();
        node->kind     = ExprKind::AlignOfExpr;
        node->range    = range;
        node->type_arg = type_arg;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *AlignOfExpr {
        var node            = ctx->alloc::<AlignOfExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::AlignOfExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool { return ptr->kind == ExprKind::AlignOfExpr; }
    static fn expr_kind() -> ExprKind { return ExprKind::AlignOfExpr; }
}

///
///  TypeOfExpr
///  typeof expr | typeof(expr)
///
class TypeOfExpr derives Expr {
    pub var operand:      *Expr;
    pub var resolved_type: *Type = &null; ///< set by sema.

    static fn create(ctx: *ASTContext, range: SourceRange, operand: *Expr) -> *TypeOfExpr {
        var node      = ctx->alloc::<TypeOfExpr>();
        node->kind    = ExprKind::TypeOfExpr;
        node->range   = range;
        node->operand = operand;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *TypeOfExpr {
        var node            = ctx->alloc::<TypeOfExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::TypeOfExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool { return ptr->kind == ExprKind::TypeOfExpr; }
    static fn expr_kind() -> ExprKind { return ExprKind::TypeOfExpr; }
}

///
///  EvalExpr
///  eval expr forces compile-time evaluation.
///
class EvalExpr derives Expr {
    pub var operand: *Expr;

    static fn create(ctx: *ASTContext, range: SourceRange, operand: *Expr) -> *EvalExpr {
        var node      = ctx->alloc::<EvalExpr>();
        node->kind    = ExprKind::EvalExpr;
        node->range   = range;
        node->operand = operand;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *EvalExpr {
        var node            = ctx->alloc::<EvalExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::EvalExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool { return ptr->kind == ExprKind::EvalExpr; }
    static fn expr_kind() -> ExprKind { return ExprKind::EvalExpr; }
}

///
///  UnsafeExpr
///  unsafe expr permits otherwise-restricted operations.
///
class UnsafeExpr derives Expr {
    pub var operand: *Expr;

    static fn create(ctx: *ASTContext, range: SourceRange, operand: *Expr) -> *UnsafeExpr {
        var node      = ctx->alloc::<UnsafeExpr>();
        node->kind    = ExprKind::UnsafeExpr;
        node->range   = range;
        node->operand = operand;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *UnsafeExpr {
        var node            = ctx->alloc::<UnsafeExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::UnsafeExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool { return ptr->kind == ExprKind::UnsafeExpr; }
    static fn expr_kind() -> ExprKind { return ExprKind::UnsafeExpr; }
}

///
///  DeleteExpr
///  delete expr | delete [expr]
///
class DeleteExpr derives Expr {
    pub var operand:  *Expr;
    pub var is_array: bool;

    static fn create(
        ctx:      *ASTContext,
        range:    SourceRange,
        operand:  *Expr,
        is_array: bool
    ) -> *DeleteExpr {
        var node       = ctx->alloc::<DeleteExpr>();
        node->kind     = ExprKind::DeleteExpr;
        node->range    = range;
        node->operand  = operand;
        node->is_array = is_array;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *DeleteExpr {
        var node            = ctx->alloc::<DeleteExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::DeleteExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool { return ptr->kind == ExprKind::DeleteExpr; }
    static fn expr_kind() -> ExprKind { return ExprKind::DeleteExpr; }
}

///
///  PackExpansionExpr
///  foo... variadic unpack expansion.
///
class PackExpansionExpr derives Expr {
    pub var operand: *Expr;

    static fn create(ctx: *ASTContext, range: SourceRange, operand: *Expr) -> *PackExpansionExpr {
        var node      = ctx->alloc::<PackExpansionExpr>();
        node->kind    = ExprKind::PackExpansionExpr;
        node->range   = range;
        node->operand = operand;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *PackExpansionExpr {
        var node            = ctx->alloc::<PackExpansionExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::PackExpansionExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool { return ptr->kind == ExprKind::PackExpansionExpr; }
    static fn expr_kind() -> ExprKind { return ExprKind::PackExpansionExpr; }
}

///
///  TypeCastExpr
///  expr as Type
///  expr as unsafe *Derived   (unsafe pointer cast)
///
class TypeCastExpr derives Expr {
    pub var operand:   *Expr;
    pub var target:    *Type;
    pub var is_unsafe: bool;

    static fn create(
        ctx:       *ASTContext,
        range:     SourceRange,
        operand:   *Expr,
        target:    *Type,
        is_unsafe: bool = false
    ) -> *TypeCastExpr {
        var node        = ctx->alloc::<TypeCastExpr>();
        node->kind      = ExprKind::TypeCastExpr;
        node->range     = range;
        node->operand   = operand;
        node->target    = target;
        node->is_unsafe = is_unsafe;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *TypeCastExpr {
        var node            = ctx->alloc::<TypeCastExpr>();
        node->kind          = ExprKind::RecoveryExpr;
        node->recovery_kind = ExprKind::TypeCastExpr;
        node->range         = range;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool { return ptr->kind == ExprKind::TypeCastExpr; }
    static fn expr_kind() -> ExprKind { return ExprKind::TypeCastExpr; }
}

///
///  ImplicitBoundaryCastExpr
///  Inserted by sema at FFI call boundaries. Not visible in source.
///  Carries original expr + source type + target ABI type for codegen.
///
class ImplicitBoundaryCastExpr derives Expr {
    pub var original:    *Expr;
    pub var source_type: *Type;
    pub var target_type: *Type;

    static fn create(
        ctx:         *ASTContext,
        range:       SourceRange,
        original:    *Expr,
        source_type: *Type,
        target_type: *Type
    ) -> *ImplicitBoundaryCastExpr {
        var node          = ctx->alloc::<ImplicitBoundaryCastExpr>();
        node->kind        = ExprKind::ImplicitBoundaryCastExpr;
        node->range       = range;
        node->original    = original;
        node->source_type = source_type;
        node->target_type = target_type;
        node->annotations.set_allocator(&(ctx->nodes));
        return node;
    }

    static fn classof(ptr: *Expr) -> bool { return ptr->kind == ExprKind::ImplicitBoundaryCastExpr; }
    static fn expr_kind() -> ExprKind { return ExprKind::ImplicitBoundaryCastExpr; }
}

// // free function: is_primary_expr
// eval fn is_primary_expr(expr: *Expr) -> bool {
//     switch expr->kind {
//         case ExprKind::IntegerLiteralExpr:
//         case ExprKind::FloatingLiteralExpr:
//         case ExprKind::StringLiteralExpr:
//         case ExprKind::CharacterLiteralExpr:
//         case ExprKind::BooleanLiteralExpr:
//         case ExprKind::NullLiteralExpr:
//         case ExprKind::ListLiteralExpr:
//         case ExprKind::TupleLiteralExpr:
//         case ExprKind::SetLiteralExpr:
//         case ExprKind::MapLiteralExpr:
//         case ExprKind::ArrayInitializerExpr:
//         case ExprKind::VectorInitializerExpr:
//         case ExprKind::MapInitializerExpr:
//         case ExprKind::SetInitializerExpr:
//         case ExprKind::NamedInitializerExpr: // ambiguous
//         case ExprKind::AnonInitializerExpr:
//         case ExprKind::ChainExpr: // ambiguous
//         case ExprKind::NamedIdentExpr:
//         case ExprKind::SelfExpr:
//         case ExprKind::GroupingExpr:
//         case ExprKind::IfExpr:
//         case ExprKind::InlineTryCatchExpr:
//         case ExprKind::ClosureExpr:
//         case ExprKind::MacroInvocationExpr: // ambiguous
//         case ExprKind::SizeOfExpr:
//         case ExprKind::AlignOfExpr:
//         case ExprKind::TypeOfExpr:
//         case ExprKind::AwaitExpr:
//         case ExprKind::SpawnExpr:
//         case ExprKind::ThreadExpr:
//         case ExprKind::EvalExpr:
//         case ExprKind::UnaryOperatorExpr: // ambiguous
//         case ExprKind::PackExpansionExpr: // ambiguous
//             return true;

//         default:
//             return false;
//     }

//     return false;
// }