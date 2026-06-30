/// --- The Kairo Project ------------------------ AST/Node/Statements.k --- ///
///
///   Statement-position AST nodes.
///
///   Every concrete Stmt subclass sets `kind` to its StmtKind and provides
///   `create` / `create_error` factories plus `classof` / `stmt_kind` for
///   the RTTI-free casting system (see Casting.k).
///
///   NOTE: ASTContext::alloc does NOT run constructors. Every field a node
///         relies on must be assigned explicitly in `create`. FrozenList
///         members are left untouched here and MUST be populated by the
///         parser via `from_buf(..., ctx)` even when empty (size 0).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------------- ///

import AST::Node::Base::*;
import AST::Context::ASTContext::*;
import AST::ASTSupport::*;
import AST::Node::PrimaryExpressions::*;
import Location::SourceRange::*;
import Token::Token::*;
import AST::Node::Patterns::*;

///
///  Binding shorthand qualifiers
///
///  Bitmask of the declaration shorthands documented under Variables:
///    `var *x`         -> Pointer
///    `var unsafe *x`  -> Pointer | Unsafe
///    `var x?`         -> Nullable
///    `var unsafe *x?` -> Pointer | Unsafe | Nullable
///
///  These reshape the *inferred* type of the binding; sema applies them after
///  inferring the underlying type from the destructured/iterated source.
///
enum BindingShorthand derives u8 {
    None     = 0,
    Pointer  = 1 << 0, ///< `*x`        leading star.
    Unsafe   = 1 << 1, ///< `unsafe *x` raw pointer; only valid with Pointer.
    Nullable = 1 << 2, ///< `x?`        nullable suffix.
}

///
///  Binding
///
///  A single introduced name in a binding position. Shared by:
///    - DestructuringDeclStmt   `var (a, const b) = t`
///    - RangedForStmt           `for var (k, const v) in m`
///    - ContextBindingStmt      `f() as var (handle, const status) { }`
///
///  Mutability rule (resolved by the parser, stored here): the leading
///  keyword (`var`/`const`) sets the default; a per-element `var`/`const`
///  overrides it. `is_const` is the RESOLVED value. `is_explicit` records
///  whether this element wrote its own keyword (for redundant-qualifier
///  diagnostics). `_` produces a discard with `is_discard = true` and a null
///  `name`.
///
struct Binding {
    var name:        *NamedIdentExpr;  ///< null when is_discard.
    var is_const:    bool;             ///< resolved mutability (default + override).
    var is_explicit: bool;             ///< this element wrote its own var/const.
    var is_discard:  bool;             ///< `_` placeholder; name is null.
    var shorthand:   BindingShorthand; ///< *, unsafe *, ? shorthands.
    var range:       SourceRange;      ///< span of this binding element.
}

///
///  CatchArm
///
///  One arm of a `try`/`catch` statement:
///    `catch e: std::Error::IO { }`  -> filter + binding
///    `catch e { }`                  -> binding, no filter
///    `catch { }`                    -> bare catch-all, neither
///
struct CatchArm {
    var filter:  *Type;           ///< panic-type filter; null for bare catch-all.
    var binding: *NamedIdentExpr; ///< bound error name; null if unbound.
    var body:    *CompoundStmt;
    var range:   SourceRange;
}

///
///  Destructure kind discriminator for DestructuringDeclStmt.
///
enum DestructureKind derives u8 {
    Tuple,  ///< `var (a, b) = t`   positional.
    Struct, ///< `var {a, b} = s`   by field name.
}

///
///  Foreign-block language for InlineBlockStmt.
///
enum InlineLang derives u8 {
    Asm,    ///< inline "asm" { }
    C,      ///< inline "c"   { }
    Cpp,    ///< inline "c++" { }
    Cuda,   ///< inline "cuda" { }
    Hip,    ///< inline "hip" { }
    OpenCL, ///< inline "opencl" { }
    Hlsl,   ///< inline "hlsl" { }
    Metal,  ///< inline "metal" { }
    SpirV,  ///< inline "spirv" { }
    Wgsl,   ///< inline "wgsl" { }
    Glsl,   ///< inline "glsl" { }
    Kairo,  ///< inline "kairo" { }
}

///
///  ExpressionStmt
///  Grammar:  expr
///
///  An expression in statement position; its value is discarded.
///
class ExpressionStmt derives Stmt {
    pub var expr: *Expr;

    static fn create(ctx: *ASTContext, range: SourceRange, expr: *Expr) -> *ExpressionStmt {
        var node   = ctx->alloc::<ExpressionStmt>();
        node->kind  = StmtKind::ExpressionStmt;
        node->range = range;
        node->init_annotations(&(ctx->nodes));;
        node->expr  = expr;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ExpressionStmt {
        var node            = ctx->alloc::<ExpressionStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::ExpressionStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::ExpressionStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::ExpressionStmt;
    }
}

///
///  DeclStmt
///  Grammar:  decl    (var/const/fn/class/struct/enum/... at stmt scope)
///
///  Wraps a declaration appearing inside a function body.
///
class DeclStmt derives Stmt {
    pub var decl: *Decl;

    static fn create(ctx: *ASTContext, range: SourceRange, decl: *Decl) -> *DeclStmt {
        var node   = ctx->alloc::<DeclStmt>();
        node->kind  = StmtKind::DeclStmt;
        node->range = range;
        node->init_annotations(&(ctx->nodes));;
        node->decl  = decl;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *DeclStmt {
        var node            = ctx->alloc::<DeclStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::DeclStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::DeclStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::DeclStmt;
    }
}

///
///  ReturnStmt
///  Grammar:  'return' | 'return' expr
///
class ReturnStmt derives Stmt {
    pub var value: *Expr; ///< null for a bare `return`.

    static fn create(ctx: *ASTContext, range: SourceRange, value: *Expr) -> *ReturnStmt {
        var node   = ctx->alloc::<ReturnStmt>();
        node->kind  = StmtKind::ReturnStmt;
        node->range = range;
        node->init_annotations(&(ctx->nodes));;
        node->value = value;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ReturnStmt {
        var node            = ctx->alloc::<ReturnStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::ReturnStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::ReturnStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::ReturnStmt;
    }
}

///
///  BreakStmt
///  Grammar:  'break' | 'break' identifier
///
class BreakStmt derives Stmt {
    pub var has_label: bool;  ///< true if a loop label follows.
    pub var label:     Token; ///< meaningful only when has_label.

    static fn create(ctx: *ASTContext, range: SourceRange, has_label: bool, label: Token) -> *BreakStmt {
        var node       = ctx->alloc::<BreakStmt>();
        node->kind      = StmtKind::BreakStmt;
        node->range     = range;
        node->init_annotations(&(ctx->nodes));;
        node->has_label = has_label;
        node->label     = label;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *BreakStmt {
        var node            = ctx->alloc::<BreakStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::BreakStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::BreakStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::BreakStmt;
    }
}

///
///  ContinueStmt
///  Grammar:  'continue' | 'continue' identifier
///
class ContinueStmt derives Stmt {
    pub var has_label: bool;
    pub var label:     Token;

    static fn create(ctx: *ASTContext, range: SourceRange, has_label: bool, label: Token) -> *ContinueStmt {
        var node       = ctx->alloc::<ContinueStmt>();
        node->kind      = StmtKind::ContinueStmt;
        node->range     = range;
        node->init_annotations(&(ctx->nodes));;
        node->has_label = has_label;
        node->label     = label;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ContinueStmt {
        var node            = ctx->alloc::<ContinueStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::ContinueStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::ContinueStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::ContinueStmt;
    }
}

///
///  PanicStmt
///  Grammar:  'panic' expr
///
///  Only legal in functions carrying the `panic` specifier (sema-checked).
///
class PanicStmt derives Stmt {
    pub var payload: *Expr;

    static fn create(ctx: *ASTContext, range: SourceRange, payload: *Expr) -> *PanicStmt {
        var node     = ctx->alloc::<PanicStmt>();
        node->kind    = StmtKind::PanicStmt;
        node->range   = range;
        node->init_annotations(&(ctx->nodes));;
        node->payload = payload;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *PanicStmt {
        var node            = ctx->alloc::<PanicStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::PanicStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::PanicStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::PanicStmt;
    }
}

///
///  YieldStmt
///  Grammar:  'yield' expr
///
///  Only legal in functions returning a `yield T` type (sema-checked).
///
class YieldStmt derives Stmt {
    pub var value: *Expr;

    static fn create(ctx: *ASTContext, range: SourceRange, value: *Expr) -> *YieldStmt {
        var node   = ctx->alloc::<YieldStmt>();
        node->kind  = StmtKind::YieldStmt;
        node->range = range;
        node->init_annotations(&(ctx->nodes));;
        node->value = value;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *YieldStmt {
        var node            = ctx->alloc::<YieldStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::YieldStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::YieldStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::YieldStmt;
    }
}

///
///  RuntimeAssertStmt
///  Grammar:  'assert' expr (',' expr)?
///
///  Runtime assertion. Behavior controlled by -fassert-mode. `message` is the
///  optional second operand.
///
class RuntimeAssertStmt derives Stmt {
    pub var condition: *Expr;
    pub var message:   *Expr; ///< null if no message operand.

    static fn create(ctx: *ASTContext, range: SourceRange, condition: *Expr, message: *Expr) -> *RuntimeAssertStmt {
        var node       = ctx->alloc::<RuntimeAssertStmt>();
        node->kind      = StmtKind::RuntimeAssertStmt;
        node->range     = range;
        node->init_annotations(&(ctx->nodes));;
        node->condition = condition;
        node->message   = message;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *RuntimeAssertStmt {
        var node            = ctx->alloc::<RuntimeAssertStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::RuntimeAssertStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::RuntimeAssertStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::RuntimeAssertStmt;
    }
}

///
///  StaticAssertStmt
///  Grammar:  'assert' 'static' expr (',' expr)?
///
///  Compile-time assertion. `condition` must be const-evaluable; failure is a
///  compile error. `message` is the optional second operand.
///
class StaticAssertStmt derives Stmt {
    pub var condition: *Expr;
    pub var message:   *Expr; ///< null if no message operand.

    static fn create(ctx: *ASTContext, range: SourceRange, condition: *Expr, message: *Expr) -> *StaticAssertStmt {
        var node       = ctx->alloc::<StaticAssertStmt>();
        node->kind      = StmtKind::StaticAssertStmt;
        node->range     = range;
        node->init_annotations(&(ctx->nodes));;
        node->condition = condition;
        node->message   = message;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *StaticAssertStmt {
        var node            = ctx->alloc::<StaticAssertStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::StaticAssertStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::StaticAssertStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::StaticAssertStmt;
    }
}

///
///  LabelIntrinsicStmt
///  Grammar:  'label' '!' '(' identifier ')'
///
///  Declares a raw branch target. Distinct from a structured loop label
///  (LabeledStmt). Surfaced as macro syntax, parsed as a first-class node.
///
class LabelIntrinsicStmt derives Stmt {
    pub var name: Token;

    static fn create(ctx: *ASTContext, range: SourceRange, name: Token) -> *LabelIntrinsicStmt {
        var node   = ctx->alloc::<LabelIntrinsicStmt>();
        node->kind  = StmtKind::LabelIntrinsicStmt;
        node->range = range;
        node->init_annotations(&(ctx->nodes));;
        node->name  = name;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *LabelIntrinsicStmt {
        var node            = ctx->alloc::<LabelIntrinsicStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::LabelIntrinsicStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::LabelIntrinsicStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::LabelIntrinsicStmt;
    }
}

///
///  JumpIntrinsicStmt
///  Grammar:  'jump' '!' '(' identifier ')'
///
///  Unconditional jump to a `label!`-declared target in the same function.
///  Bypasses destructors and finally blocks.
///
class JumpIntrinsicStmt derives Stmt {
    pub var target: Token;

    static fn create(ctx: *ASTContext, range: SourceRange, target: Token) -> *JumpIntrinsicStmt {
        var node    = ctx->alloc::<JumpIntrinsicStmt>();
        node->kind   = StmtKind::JumpIntrinsicStmt;
        node->range  = range;
        node->init_annotations(&(ctx->nodes));;
        node->target = target;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *JumpIntrinsicStmt {
        var node            = ctx->alloc::<JumpIntrinsicStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::JumpIntrinsicStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::JumpIntrinsicStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::JumpIntrinsicStmt;
    }
}

///
///  ConditionalStmt
///  Grammar:  'if' expr block ('else' 'if' expr block)* ('else' block)?
///
///  `then_` is always a block. `else_` is nullable and is either the next
///  ConditionalStmt (an `else if`) or a CompoundStmt (the final `else`).
///  (Deviates from the doc-2 comment that says both branches are CompoundStmt;
///   *Stmt avoids wrapping else-if chains in throwaway blocks.)
///
class ConditionalStmt derives Stmt {
    pub var cond:  *Expr;
    pub var then_: *CompoundStmt;
    pub var else_: *Stmt; ///< null, a ConditionalStmt (else-if), or a CompoundStmt.

    static fn create(
        ctx:   *ASTContext,
        range: SourceRange,
        cond:  *Expr,
        then_: *CompoundStmt,
        else_: *Stmt
    ) -> *ConditionalStmt {
        var node   = ctx->alloc::<ConditionalStmt>();
        node->kind  = StmtKind::ConditionalStmt;
        node->range = range;
        node->init_annotations(&(ctx->nodes));;
        node->cond  = cond;
        node->then_ = then_;
        node->else_ = else_;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ConditionalStmt {
        var node            = ctx->alloc::<ConditionalStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::ConditionalStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::ConditionalStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::ConditionalStmt;
    }
}

///
///  WhileLoopStmt
///  Grammar:  'while' expr block
///
class WhileLoopStmt derives Stmt {
    pub var cond: *Expr;
    pub var body: *CompoundStmt;

    static fn create(ctx: *ASTContext, range: SourceRange, cond: *Expr, body: *CompoundStmt) -> *WhileLoopStmt {
        var node   = ctx->alloc::<WhileLoopStmt>();
        node->kind  = StmtKind::WhileLoopStmt;
        node->range = range;
        node->init_annotations(&(ctx->nodes));;
        node->cond  = cond;
        node->body  = body;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *WhileLoopStmt {
        var node            = ctx->alloc::<WhileLoopStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::WhileLoopStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::WhileLoopStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::WhileLoopStmt;
    }
}

///
///  LoopStmt
///  Grammar:  'loop' block
///
///  Unconditional infinite loop. Runs until `break` or `return`.
///
class LoopStmt derives Stmt {
    pub var body: *CompoundStmt;

    static fn create(ctx: *ASTContext, range: SourceRange, body: *CompoundStmt) -> *LoopStmt {
        var node   = ctx->alloc::<LoopStmt>();
        node->kind  = StmtKind::LoopStmt;
        node->range = range;
        node->init_annotations(&(ctx->nodes));;
        node->body  = body;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *LoopStmt {
        var node            = ctx->alloc::<LoopStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::LoopStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::LoopStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::LoopStmt;
    }
}

///
///  RangedForStmt
///  Grammar:  'eval'? 'for' binding_spec 'in' expr block
///    binding_spec := ('var'|'const')? (binding | '(' binding (',' binding)* ')')
///
///  `bindings` holds the loop bindings (1 for `for var x in`, N for a tuple
///  destructure `for var (k, const v) in`). `is_eval` marks the compile-time
///  unroll form. `iterable` must implement `fn op in (self) -> yield T`.
///
class RangedForStmt derives Stmt {
    pub var bindings: FrozenList::<Binding>;
    pub var iterable: *Expr;
    pub var body:     *CompoundStmt;
    pub var is_eval:  bool;

    static fn create(
        ctx:      *ASTContext,
        range:    SourceRange,
        iterable: *Expr,
        body:     *CompoundStmt,
        is_eval:  bool
    ) -> *RangedForStmt {
        var node      = ctx->alloc::<RangedForStmt>();
        node->kind     = StmtKind::RangedForStmt;
        node->range    = range;
        node->init_annotations(&(ctx->nodes));;
        node->iterable = iterable;
        node->body     = body;
        node->is_eval  = is_eval;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *RangedForStmt {
        var node            = ctx->alloc::<RangedForStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::RangedForStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::RangedForStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::RangedForStmt;
    }
}

///
///  IndexedForStmt
///  Grammar:  'eval'? 'for' decl_stmt ';' expr ';' expr block
///
///  C-style three-part for. `init` declares a loop-scoped variable (a
///  DeclStmt). `cond` and `update` are bare expressions. `is_eval` marks the
///  compile-time unroll form.
///
class IndexedForStmt derives Stmt {
    pub var init:    *Stmt; ///< the loop-variable declaration (DeclStmt).
    pub var cond:    *Expr;
    pub var update:  *Expr;
    pub var body:    *CompoundStmt;
    pub var is_eval: bool;

    static fn create(
        ctx:     *ASTContext,
        range:   SourceRange,
        init:    *Stmt,
        cond:    *Expr,
        update:  *Expr,
        body:    *CompoundStmt,
        is_eval: bool
    ) -> *IndexedForStmt {
        var node     = ctx->alloc::<IndexedForStmt>();
        node->kind    = StmtKind::IndexedForStmt;
        node->range   = range;
        node->init_annotations(&(ctx->nodes));;
        node->init    = init;
        node->cond    = cond;
        node->update  = update;
        node->body    = body;
        node->is_eval = is_eval;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *IndexedForStmt {
        var node            = ctx->alloc::<IndexedForStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::IndexedForStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::IndexedForStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::IndexedForStmt;
    }
}

///
///  MatchStmt
///  Grammar:  'match' expr '{' match_case* '}'
///    match_case := 'case' pattern (',' pattern)* ('where' expr)? block
///                | 'default' block
///
///  Statement-position match. Non-exhaustive matching on integer/string
///  scrutinees is permitted (sema), unlike the expression form.
///
class MatchStmt derives Stmt {
    pub var scrutinee: *Expr;
    pub var cases:     FrozenList::<MatchCase>;

    static fn create(ctx: *ASTContext, range: SourceRange, scrutinee: *Expr) -> *MatchStmt {
        var node       = ctx->alloc::<MatchStmt>();
        node->kind      = StmtKind::MatchStmt;
        node->range     = range;
        node->init_annotations(&(ctx->nodes));;
        node->scrutinee = scrutinee;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *MatchStmt {
        var node            = ctx->alloc::<MatchStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::MatchStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::MatchStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::MatchStmt;
    }
}

///
///  LabeledStmt
///  Grammar:  identifier ':' (while_stmt | ranged_for | indexed_for | loop_stmt)
///
///  Only legal on loop statements. Provides the target for `break label` /
///  `continue label`.
///
class LabeledStmt derives Stmt {
    pub var label: Token;
    pub var inner: *Stmt; ///< the labeled loop statement.

    static fn create(ctx: *ASTContext, range: SourceRange, label: Token, inner: *Stmt) -> *LabeledStmt {
        var node   = ctx->alloc::<LabeledStmt>();
        node->kind  = StmtKind::LabeledStmt;
        node->range = range;
        node->init_annotations(&(ctx->nodes));;
        node->label = label;
        node->inner = inner;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *LabeledStmt {
        var node            = ctx->alloc::<LabeledStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::LabeledStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::LabeledStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::LabeledStmt;
    }
}

///
///  TryCatchStmt
///  Grammar:  'try' block ('catch' catch_filter? block)+
///    catch_filter := identifier (':' type)?
///
///  `finally` is NOT a clause here; `try { } finally { }` parses as a
///  TryCatchStmt followed by a separate FinallyStmt. `arms` holds the catch
///  arms; a bare `catch { }` arm has both filter and binding null.
///
class TryCatchStmt derives Stmt {
    pub var try_body: *CompoundStmt;
    pub var arms:     FrozenList::<CatchArm>;

    static fn create(ctx: *ASTContext, range: SourceRange, try_body: *CompoundStmt) -> *TryCatchStmt {
        var node      = ctx->alloc::<TryCatchStmt>();
        node->kind     = StmtKind::TryCatchStmt;
        node->range    = range;
        node->init_annotations(&(ctx->nodes));;
        node->try_body = try_body;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *TryCatchStmt {
        var node            = ctx->alloc::<TryCatchStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::TryCatchStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::TryCatchStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::TryCatchStmt;
    }
}

///
///  FinallyStmt
///  Grammar:  'finally' block
///
///  Standalone deferred cleanup. Runs at function exit in reverse declaration
///  order (LIFO).
///
class FinallyStmt derives Stmt {
    pub var body: *CompoundStmt;

    static fn create(ctx: *ASTContext, range: SourceRange, body: *CompoundStmt) -> *FinallyStmt {
        var node   = ctx->alloc::<FinallyStmt>();
        node->kind  = StmtKind::FinallyStmt;
        node->range = range;
        node->init_annotations(&(ctx->nodes));;
        node->body  = body;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *FinallyStmt {
        var node            = ctx->alloc::<FinallyStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::FinallyStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::FinallyStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::FinallyStmt;
    }
}

///
///  UnsafeBlockStmt
///  Grammar:  'unsafe' block
///
///  Introduces an UnsafeContext. Suspends AMT tracking for the body.
///
class UnsafeBlockStmt derives Stmt {
    pub var body: *CompoundStmt;

    static fn create(ctx: *ASTContext, range: SourceRange, body: *CompoundStmt) -> *UnsafeBlockStmt {
        var node   = ctx->alloc::<UnsafeBlockStmt>();
        node->kind  = StmtKind::UnsafeBlockStmt;
        node->range = range;
        node->init_annotations(&(ctx->nodes));;
        node->body  = body;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *UnsafeBlockStmt {
        var node            = ctx->alloc::<UnsafeBlockStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::UnsafeBlockStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::UnsafeBlockStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::UnsafeBlockStmt;
    }
}

///
///  ContextBindingStmt
///  Grammar:  expr 'as' binding_spec block
///    binding_spec := ('var'|'const') (binding | '(' binding (',' binding)* ')')
///
///  Scope-bound resource (Python `with` / C# `using`). The expr parser, on
///  seeing `as` followed by `var`/`const`, rolls back and leaves `as`
///  unconsumed; the statement parser owns this production from there. The
///  binding(s) live for the body block. Sema lowers via conformance to the
///  context protocol (enter/exit). `bindings` is populated by the parser.
///
///  A binding_spec with no following block is a hard error (it is neither a
///  valid cast nor a valid context block).
///
class ContextBindingStmt derives Stmt {
    pub var value:    *Expr;
    pub var bindings: FrozenList::<Binding>;
    pub var body:     *CompoundStmt;

    static fn create(ctx: *ASTContext, range: SourceRange, value: *Expr, body: *CompoundStmt) -> *ContextBindingStmt {
        var node   = ctx->alloc::<ContextBindingStmt>();
        node->kind  = StmtKind::ContextBindingStmt;
        node->range = range;
        node->init_annotations(&(ctx->nodes));;
        node->value = value;
        node->body  = body;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ContextBindingStmt {
        var node            = ctx->alloc::<ContextBindingStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::ContextBindingStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::ContextBindingStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::ContextBindingStmt;
    }
}

///
///  DestructuringDeclStmt
///  Grammar:  ('var'|'const') (tuple_pat | struct_pat) '=' expr
///    tuple_pat  := '(' binding (',' binding)* ')'
///    struct_pat := '{' binding (',' binding)* '}'
///
///  `kind` distinguishes positional (tuple) from by-field-name (struct)
///  destructuring. `leading_is_const` records the lead keyword (each Binding
///  also carries its own resolved `is_const`). `bindings` is parser-populated.
///
class DestructuringDeclStmt derives Stmt {
    pub var kind_:            DestructureKind; ///< Tuple vs Struct. (kind_ to avoid Stmt::kind clash.)
    pub var bindings:         FrozenList::<Binding>;
    pub var value:            *Expr;
    pub var leading_is_const: bool;

    static fn create(
        ctx:              *ASTContext,
        range:            SourceRange,
        destructure_kind: DestructureKind,
        value:            *Expr,
        leading_is_const: bool
    ) -> *DestructuringDeclStmt {
        var node             = ctx->alloc::<DestructuringDeclStmt>();
        node->kind            = StmtKind::DestructuringDeclStmt;
        node->range           = range;
        node->init_annotations(&(ctx->nodes));;
        node->kind_           = destructure_kind;
        node->value           = value;
        node->leading_is_const = leading_is_const;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *DestructuringDeclStmt {
        var node            = ctx->alloc::<DestructuringDeclStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::DestructuringDeclStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::DestructuringDeclStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::DestructuringDeclStmt;
    }
}

///
///  InlineBlockStmt
///  Grammar:  'inline' string_literal '{' <opaque body> '}'
///
///  Foreign block. The body is opaque to the Kairo parser and handed to the
///  foreign backend unmodified; `body_span` covers the raw inner text.
///
class InlineBlockStmt derives Stmt {
    pub var lang:      InlineLang;
    pub var body_span: SourceRange; ///< raw inner body, excluding braces.

    static fn create(ctx: *ASTContext, range: SourceRange, lang: InlineLang, body_span: SourceRange) -> *InlineBlockStmt {
        var node       = ctx->alloc::<InlineBlockStmt>();
        node->kind      = StmtKind::InlineBlockStmt;
        node->range     = range;
        node->init_annotations(&(ctx->nodes));;
        node->lang      = lang;
        node->body_span = body_span;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *InlineBlockStmt {
        var node            = ctx->alloc::<InlineBlockStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::InlineBlockStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::InlineBlockStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::InlineBlockStmt;
    }
}

///
///  EvalBlockStmt
///  Grammar:  'eval' '{' decl* '}'
///
///  Decl-only compile-time block. Statements inside are a sema error (parser
///  still recovers). `eval if` / `eval for` / `eval var` are handled by their
///  own stmt/decl nodes with `is_eval = true`, NOT by this kind.
///
class EvalBlockStmt derives Stmt {
    pub var body: FrozenList::<*Decl>;

    static fn create(ctx: *ASTContext, range: SourceRange) -> *EvalBlockStmt {
        var node   = ctx->alloc::<EvalBlockStmt>();
        node->kind  = StmtKind::EvalBlockStmt;
        node->range = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *EvalBlockStmt {
        var node            = ctx->alloc::<EvalBlockStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::EvalBlockStmt;
        node->range         = range;
        node->init_annotations(&(ctx->nodes));;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::EvalBlockStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::EvalBlockStmt;
    }
}

enum InlineBlockLang derives u8 {
    /// Clang: -x assembler-with-cpp
    /// inline "asm" { }
    Asm,

    /// Clang: -x c
    /// inline "c" { }
    C,

    /// Clang: -x c++
    /// inline "c++" { }
    Cxx,

    /// Clang: -x cuda  (requires CUDA toolkit)
    /// inline "cuda" { }
    Cuda,

    /// Clang: -x hip  (requires ROCm)
    /// inline "hip" { }
    Hip,

    /// Clang: -x opencl
    /// inline "OpenCL" { }
    OpenCL,

    /// Clang: -x hlsl  (Clang 15+)
    /// inline "hlsl" { }
    Hlsl,

    /// Apple metal compiler (xcrun metal), NOT standard Clang
    /// requires Apple toolchain
    /// inline "metal" { }
    Metal,

    /// OpenCL source compiled to SPIR-V via --target=spirv32/spirv64
    /// not a separate language, just OpenCL with a different target
    /// inline "spirv" { }
    SpirV,

    /// naga or tint compiler, NOT Clang
    /// requires separate WGSL toolchain
    /// inline "wgsl" { }
    Wgsl,

    /// glslang or shaderc, NOT Clang
    /// requires separate GLSL toolchain
    /// inline "glsl" { }
    Glsl,

    /// does absolutely nothing, just for fucks and giggles
    /// ACTUALLY MIGHT BE USEFUL FOR ADDING KAIRO DIRECTLY INTO C++ CODE
    /// inline "kairo" { }
    Kairo,
};