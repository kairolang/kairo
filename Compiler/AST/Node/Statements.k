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
    var type_:       *Type = &null;    ///< explicit `: T` ascription; null if none.
    var range:       SourceRange;      ///< span of this binding element.

    /// The DECLARATION this binder introduces (`for x in xs` declares `x`).
    /// Synthesized by the parser alongside `name`, null for a discard.
    /// Typed *Decl (always a VariableDecl) to dodge a stage0 import cycle, the
    /// same dodge TranslationUnit::out_of_line uses; downcast at use.
    ///
    /// A binder is a declaration, so uses of it must have something to bind
    /// to: NameResolution pushes this decl onto its lexical stack and writes
    /// it into each use's `resolved_decl`. Without it every `for` body that
    /// mentions its loop variable reported unresolved-ident. TypeResolution
    /// later hangs the inferred element type here.
    ///
    /// NOT in any symbol table and NOT reachable from dc_decls: locals are
    /// excluded from tables by design, and the RAV does not dispatch it
    /// (which would double-declare it).
    var decl:        *Decl = &null;
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
    /// Declaration introduced by `binding`; see Binding::decl. Null when the
    /// arm binds no name.
    var decl:    *Decl = &null;
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
enum FFILang derives u8 {
    None,   ///< wrong language; parser error.
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
        node->init_annotations(&(ctx->ast_alloc));;
        node->expr  = expr;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ExpressionStmt {
        var node            = ctx->alloc::<ExpressionStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::ExpressionStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
        node->decl  = decl;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *DeclStmt {
        var node            = ctx->alloc::<DeclStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::DeclStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
        node->value = value;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ReturnStmt {
        var node            = ctx->alloc::<ReturnStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::ReturnStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
        node->has_label = has_label;
        node->label     = label;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *BreakStmt {
        var node            = ctx->alloc::<BreakStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::BreakStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
        node->has_label = has_label;
        node->label     = label;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ContinueStmt {
        var node            = ctx->alloc::<ContinueStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::ContinueStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
        node->payload = payload;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *PanicStmt {
        var node            = ctx->alloc::<PanicStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::PanicStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
        node->value = value;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *YieldStmt {
        var node            = ctx->alloc::<YieldStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::YieldStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
        node->condition = condition;
        node->message   = message;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *RuntimeAssertStmt {
        var node            = ctx->alloc::<RuntimeAssertStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::RuntimeAssertStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
        node->condition = condition;
        node->message   = message;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *StaticAssertStmt {
        var node            = ctx->alloc::<StaticAssertStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::StaticAssertStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
///  Also the lowerings' labels and gotos (MatchLowering, LabelLowering);
///  EmitIR spells both. User-written ones are SC116E (FeatureGateCheck) until
///  a crossing-initialization check exists.
///
class LabelIntrinsicStmt derives Stmt {
    pub var name: Token;

    static fn create(ctx: *ASTContext, range: SourceRange, name: Token) -> *LabelIntrinsicStmt {
        var node   = ctx->alloc::<LabelIntrinsicStmt>();
        node->kind  = StmtKind::LabelIntrinsicStmt;
        node->range = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->name  = name;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *LabelIntrinsicStmt {
        var node            = ctx->alloc::<LabelIntrinsicStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::LabelIntrinsicStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
///  Also the lowerings' labels and gotos (MatchLowering, LabelLowering);
///  EmitIR spells both. User-written ones are SC116E (FeatureGateCheck) until
///  a crossing-initialization check exists.
///
class JumpIntrinsicStmt derives Stmt {
    pub var target: Token;

    static fn create(ctx: *ASTContext, range: SourceRange, target: Token) -> *JumpIntrinsicStmt {
        var node    = ctx->alloc::<JumpIntrinsicStmt>();
        node->kind   = StmtKind::JumpIntrinsicStmt;
        node->range  = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->target = target;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *JumpIntrinsicStmt {
        var node            = ctx->alloc::<JumpIntrinsicStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::JumpIntrinsicStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
///  SwitchDispatchStmt
///  Lowering-only: never parsed. MatchLowering's multiway jump:
///    switch (value) { case lo: goto L; case lo ... hi: goto L; default: goto D; }
///  or, with `default_stmt`, `default: <stmt>` (UnmatchedPolicy's call).
///  The cases hold only gotos, so no user statement ever sits inside a C++
///  switch. `hi` null: a single value; otherwise GNU `case lo ... hi:`.
///
struct DispatchCase {
    var lo:     *Expr = &null;
    var hi:     *Expr = &null;
    var target: Token;
}

class SwitchDispatchStmt derives Stmt {
    pub var value:          *Expr;
    pub var cases:          FrozenList::<DispatchCase>;   ///< filled by the lowering that mints it.
    pub var default_target: Token;           ///< meaningful when default_stmt is null.
    pub var default_stmt:   *Stmt = &null;   ///< emitted in place of `goto default_target`.

    static fn create(ctx: *ASTContext, range: SourceRange, value: *Expr) -> *SwitchDispatchStmt {
        var node   = ctx->alloc::<SwitchDispatchStmt>();
        node->kind  = StmtKind::SwitchDispatchStmt;
        node->range = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->value          = value;
        node->default_target = Token();
        node->default_stmt   = &null;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *SwitchDispatchStmt {
        var node            = ctx->alloc::<SwitchDispatchStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::SwitchDispatchStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->value         = &null;
        node->default_stmt  = &null;
        return node;
    }

    /* OVERRIDE */ static fn classof(ptr: *Stmt) -> bool {
        return ptr->kind == StmtKind::SwitchDispatchStmt;
    }
    /* OVERRIDE */ static fn stmt_kind() -> StmtKind {
        return StmtKind::SwitchDispatchStmt;
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
    /// `eval if`, and every `else if` of its chain: folded by EvalIfFolding
    /// where its condition folds, else C++ `if constexpr` (EVAL.md §4).
    pub var is_eval: bool;

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
        node->init_annotations(&(ctx->ast_alloc));;
        node->cond  = cond;
        node->then_ = then_;
        node->else_ = else_;
        node->is_eval = false;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ConditionalStmt {
        var node            = ctx->alloc::<ConditionalStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::ConditionalStmt;
        node->is_eval       = false;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
        node->cond  = cond;
        node->body  = body;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *WhileLoopStmt {
        var node            = ctx->alloc::<WhileLoopStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::WhileLoopStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
        node->body  = body;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *LoopStmt {
        var node            = ctx->alloc::<LoopStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::LoopStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
///  How IterLowering walks an iterable. Written by X (StmtTyping) when it
///  types the loop; IterLowering renders the shape and decides nothing.
///
enum IterKind derives u8 {
    None = 0,     ///< untyped, poisoned, or dependent: not lowered.
    RangeLit,     ///< `a..b` / `a..=b` written as the iterable.
    RangeValue,   ///< a Range-typed value (`var r = 0..3; for i in r`).
    Array,        ///< `[T; N]`.
    Slice,        ///< `[T;]`.
    Vector,       ///< `[T]`.
    Set,          ///< `{T}`.
    Map,          ///< `{K: V}`.
    String,       ///< `string`, by `char`.
    User,         ///< a record's `fn op in (self) -> yield T`, or a Yield<T> value itself (iter_op null).
    Cxx,          ///< an imported C++ class, by C++'s range protocol ([stmt.ranged]).
}

///
///  RangedForStmt
///  Grammar:  'eval'? 'for' binding_spec 'in' expr block
///    binding_spec := ('var'|'const')? (binding | '(' binding (',' binding)* ')')
///
///  `bindings` holds the loop bindings (1 for `for var x in`, N for a tuple
///  destructure `for var (k, const v) in`). `is_eval` marks the compile-time
///  unroll form. `iterable` is a range, a container, a record with
///  `fn op in (self) -> yield T`, or an imported C++ class C++ can range over
///  (member or free `begin`/`end`; a Kairo class's begin/end never count,
///  `op in` is its one protocol); X records which in `iter_kind`.
///
///  For Cxx, X also mints the two hidden iterator locals and types the three
///  loop operations over them, so overload resolution -- const `begin()`,
///  ADL, C++20's `!=` from `==` -- happens in X like any other expression;
///  IterLowering only places them. The `cxx_*` fields are not children: no
///  walker visits them before IterLowering puts them in the tree.
///
class RangedForStmt derives Stmt {
    pub var bindings: FrozenList::<Binding>;
    pub var iterable: *Expr;
    pub var body:     *CompoundStmt;
    pub var is_eval:  bool;
    pub var iter_kind: IterKind = IterKind::None;
    pub var iter_op:   *Decl    = &null;   ///< User: the selected `op in (self)`; null when the iterable is a Yield<T> itself.
    pub var iter_elem: *Type    = &null;   ///< the element type, canonical and unqualified.
    // Cxx only. Locals are *Decl (always a VariableDecl), the import-cycle
    // dodge Binding uses.
    pub var cxx_begin_fn:  *Decl  = &null;   ///< `begin`, a member or (cxx_free) a free function.
    pub var cxx_end_fn:    *Decl  = &null;
    pub var cxx_free:      bool   = false;   ///< begin/end are free functions found by ADL: `begin(r)`.
    pub var cxx_begin_inst: *void = &null;   ///< a generic free begin's instance, as CallExpr::instance.
    pub var cxx_end_inst:   *void = &null;
    pub var cxx_it:        *Decl  = &null;   ///< `__it`, of begin's type; init left to IterLowering.
    pub var cxx_end:       *Decl  = &null;   ///< `__end`, of end's type (a sentinel may differ).
    pub var cxx_cond:      *Expr  = &null;   ///< `__it != __end`, typed.
    pub var cxx_deref:     *Expr  = &null;   ///< `*__it`, typed: the element place.
    pub var cxx_next:      *Expr  = &null;   ///< `++__it`, typed.

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
        node->init_annotations(&(ctx->ast_alloc));;
        node->iterable = iterable;
        node->body     = body;
        node->is_eval  = is_eval;
        node->iter_kind = IterKind::None;
        node->iter_op   = &null;
        node->iter_elem = &null;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *RangedForStmt {
        var node            = ctx->alloc::<RangedForStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::RangedForStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->iter_kind     = IterKind::None;
        node->iter_op       = &null;
        node->iter_elem     = &null;
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
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
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
///  Statement-position match. Exhaustive like the expression form
///  (PatternChecking).
///
class MatchStmt derives Stmt {
    pub var scrutinee: *Expr;
    pub var cases:     FrozenList::<MatchCase>;

    /// Facts about this match. One writer: PatternChecking.
    /// is_exhaustive: every value of the scrutinee type reaches an arm.
    /// covering_arm:  the arm the remainder falls to (the last arm) when
    ///                exhaustive; -1 otherwise.
    /// open_tail:     exhaustive only because a closed enum's variants are all
    ///                listed; an undeclared discriminant reaches no arm, and
    ///                MatchLowering applies UnmatchedPolicy to it.
    pub var is_exhaustive: bool = true;
    pub var covering_arm:  i32  = -1;
    pub var open_tail:     bool = false;
    pub var decision:      *void = &null; ///< PatternCompilation's *DecisionTree. One writer: PatternCompilation; read by MatchLowering and SemaDump.
    /// A match on a `T?` whose first arm is `case null` (NULLABLE.md 3.6):
    /// every later arm matches the unwrapped `T`. One writer: X (the match
    /// typing, which also reports a `T?` match without it); read by
    /// PatternChecking and PatternCompilation (arm 0 is no row; the column
    /// is `T`), CoalesceLowering (which splits arm 0 off) and SemaDump.
    pub var null_arm:      bool  = false;

    static fn create(ctx: *ASTContext, range: SourceRange, scrutinee: *Expr) -> *MatchStmt {
        var node       = ctx->alloc::<MatchStmt>();
        node->kind      = StmtKind::MatchStmt;
        node->range     = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->scrutinee = scrutinee;
        node->is_exhaustive = true;
        node->covering_arm  = -1;
        node->open_tail     = false;
        node->decision      = &null;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *MatchStmt {
        var node            = ctx->alloc::<MatchStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::MatchStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->is_exhaustive = true;
        node->covering_arm  = -1;
        node->open_tail     = false;
        node->decision      = &null;
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
        node->init_annotations(&(ctx->ast_alloc));;
        node->label = label;
        node->inner = inner;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *LabeledStmt {
        var node            = ctx->alloc::<LabeledStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::LabeledStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
        node->try_body = try_body;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *TryCatchStmt {
        var node            = ctx->alloc::<TryCatchStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::TryCatchStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
        node->body  = body;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *FinallyStmt {
        var node            = ctx->alloc::<FinallyStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::FinallyStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
        node->body  = body;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *UnsafeBlockStmt {
        var node            = ctx->alloc::<UnsafeBlockStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::UnsafeBlockStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
        node->value = value;
        node->body  = body;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *ContextBindingStmt {
        var node            = ctx->alloc::<ContextBindingStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::ContextBindingStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
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
    pub var lang:      FFILang;
    pub var body_span: SourceRange; ///< raw inner body, excluding braces.

    static fn create(ctx: *ASTContext, range: SourceRange, lang: FFILang, body_span: SourceRange) -> *InlineBlockStmt {
        var node       = ctx->alloc::<InlineBlockStmt>();
        node->kind      = StmtKind::InlineBlockStmt;
        node->range     = range;
        node->init_annotations(&(ctx->ast_alloc));;
        node->lang      = lang;
        node->body_span = body_span;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *InlineBlockStmt {
        var node            = ctx->alloc::<InlineBlockStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::InlineBlockStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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
        node->init_annotations(&(ctx->ast_alloc));;
        return node;
    }

    static fn create_error(ctx: *ASTContext, range: SourceRange) -> *EvalBlockStmt {
        var node            = ctx->alloc::<EvalBlockStmt>();
        node->kind          = StmtKind::RecoveryStmt;
        node->recovery_kind = StmtKind::EvalBlockStmt;
        node->range         = range;
        node->init_annotations(&(ctx->ast_alloc));;
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