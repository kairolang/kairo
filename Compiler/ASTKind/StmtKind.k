/// --- The Kairo Project ---------------- Compiler/ASTKind/StmtKind.kro --- ///
///
///   \brief Discriminator enum for all statement-position AST nodes.
///
///   \detail
///     Every concrete Stmt subclass declares a static `stmt_kind()` that
///     returns one of these values. The base `Stmt::kind` field carries
///     the discriminator at runtime, allowing visitor dispatch and
///     `isa<T>` / `cast<T>` without RTTI.
///
///     Recovery (error) nodes set `kind = RecoveryStmt` and store the
///     intended `StmtKind` in `recovery_kind` so downstream consumers
///     can produce targeted diagnostics about what the parser was
///     trying to build when it failed.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://kairo-lang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Kairo Software Foundation
///
/// ------------------------------------------------------------------------ ///
///
///   StmtKind
///
///   Layout:
///     Error sentinel
///     Structural statements
///     Jump / signal statements
///     Control-flow statements
///     Exception handling
///     Scope / context modifiers
///     Compile-time blocks
///
enum StmtKind derives u8 {
    // -----------------------------------------------------------------------
    //  Sentinel
    // -----------------------------------------------------------------------

    /// Parser error sentinel. Carries the bad source range.
    /// `recovery_kind` on the Stmt base stores what we were trying to parse.
    RecoveryStmt = 0,

    // -----------------------------------------------------------------------
    //  Structural statements
    // -----------------------------------------------------------------------

    /// Compound statement / block:  { stmt* }
    /// Introduces a lexical scope. Destructors run at the closing brace
    /// in reverse declaration order.
    /// Node: CompoundStmt with FrozenList<*Stmt> body.
    CompoundStmt,

    /// Expression used as a statement:  expr
    /// The expression's value (if any) is discarded.
    /// Node: ExpressionStmt wraps an *Expr.
    ExpressionStmt,

    /// A declaration appearing at statement scope:
    ///   var x: i32 = 1
    ///   fn local() { }
    ///   class Local { }
    /// Node: DeclStmt wraps a *Decl.
    DeclStmt,

    // -----------------------------------------------------------------------
    //  Jump / signal statements
    // -----------------------------------------------------------------------

    /// Return from current function:  return | return expr
    /// Node: ReturnStmt with optional value *Expr.
    ReturnStmt,

    /// Break out of a loop:  break | break label
    /// Inside a `match` nested in a loop, `break` targets the loop.
    /// Node: BreakStmt with optional label Token.
    BreakStmt,

    /// Continue to next loop iteration:  continue | continue label
    /// Node: ContinueStmt with optional label Token.
    ContinueStmt,

    /// Raise a panic:  panic expr
    /// Only valid in functions declared with `panic` specifier.
    /// Node: PanicStmt with payload *Expr.
    PanicStmt,

    /// Yield a value from a coroutine:  yield expr
    /// Only valid in functions returning a `yield T` type.
    /// Node: YieldStmt with value *Expr.
    YieldStmt,

    /// Runtime assertion:  assert expr, "message"
    /// Behavior controlled by -fassert-mode (panic | return | log).
    /// Node: RuntimeAssertStmt with condition *Expr + optional message *Expr.
    RuntimeAssertStmt,

    /// Compile-time assertion:  assert static expr, "message"
    /// Condition must be const-evaluable. Failure is a compile error.
    /// Node: StaticAssertStmt with condition *Expr + optional message *Expr.
    StaticAssertStmt,

    /// Label intrinsic:  label!(name)
    /// Declares a raw branch target within the current function.
    /// Not a structured loop label those are LabeledStmt.
    /// Surfaced as macro syntax but parsed as a first-class AST node.
    /// Node: LabelIntrinsicStmt with name Token.
    LabelIntrinsicStmt,

    /// Jump intrinsic:  jump!(name)
    /// Unconditional jump to a `label!`-declared target in the same function.
    /// Bypasses destructors and `finally` blocks caller's responsibility.
    /// Node: JumpIntrinsicStmt with target name Token.
    JumpIntrinsicStmt,

    // -----------------------------------------------------------------------
    //  Control-flow statements
    // -----------------------------------------------------------------------

    /// Conditional statement:  if expr block (else if expr block)* (else block)?
    /// Both branches are CompoundStmt. `else_` is nullable.
    /// Note: `if` as an *expression* is IfExpr.
    /// Node: ConditionalStmt with cond + then_ + else_ (nullable).
    ConditionalStmt,

    /// While loop:  while expr block
    /// Condition evaluated before each iteration. Must be `bool`.
    /// Node: WhileLoopStmt with cond *Expr + body *CompoundStmt.
    WhileLoopStmt,

    /// Unconditional infinite loop:  loop { }
    /// Runs until `break` or `return`. Sema may use this for `-> !` analysis.
    /// Node: LoopStmt with body *CompoundStmt.
    LoopStmt,

    /// Range / iterator for loop:
    ///   for x in expr { }
    ///   for (k, v) in expr { }       // tuple destructure binding
    ///   eval for x in expr { }       // compile-time unroll
    /// Bindings are introduced by the for header; iterable must implement
    /// `fn op in (self) -> yield T`.
    /// Node: RangedForStmt with bindings + iterable + body + is_eval.
    RangedForStmt,

    /// C-style three-part for loop:
    ///   for var i = 0; i < n; i++ { }
    ///   eval for ...                 // compile-time unroll
    /// Init clause declares a new variable scoped to the loop.
    /// Node: IndexedForStmt with init + cond + update + body + is_eval.
    IndexedForStmt,

    /// Pattern match statement:  match expr { case* default? }
    /// Used in statement position (not expression). Exhaustiveness rules
    /// differ from expression-form match: statement form allows non-exhaustive
    /// matching on integer/string scrutinees.
    /// Note: `match` as an *expression* is MatchExpr.
    /// Node: MatchStmt with scrutinee *Expr + FrozenList<MatchCase>.
    MatchStmt,

    /// Labeled statement wrapper:  label: while ... | label: for ... | label: loop ...
    /// Only legal on loop statements. Provides a target for `break label` /
    /// `continue label`.
    /// Node: LabeledStmt with label Token + inner *Stmt.
    LabeledStmt,

    // -----------------------------------------------------------------------
    //  Exception handling
    // -----------------------------------------------------------------------

    /// Try / catch block:  try { } catch [pattern] { } catch { } ...
    /// Catch arms can filter by panic type or catch-all. Sema enforces that
    /// all panic types from the try body are covered.
    /// Note: `finally` is a separate statement (FinallyStmt), NOT a clause
    /// of try-catch. `try { } catch { } finally { }` parses as two stmts.
    /// Node: TryCatchStmt with try_body *CompoundStmt + FrozenList<CatchArm>.
    TryCatchStmt,

    /// Standalone deferred cleanup:  finally { }
    /// Registers a block to run at function exit, in reverse declaration
    /// order (LIFO). Matches destructor semantics.
    /// Node: FinallyStmt with body *CompoundStmt.
    FinallyStmt,

    /// Unsafe block:  unsafe { }
    /// Introduces an UnsafeContext DeclContext. Permits operations otherwise
    /// rejected by AMT and the safety analyzer.
    /// Node: UnsafeBlockStmt with body *CompoundStmt.
    UnsafeBlockStmt,

    // -----------------------------------------------------------------------
    //  Scope / context modifiers
    // -----------------------------------------------------------------------

    /// Context / with statement:  expr as binding { body }
    ///   file as f { f.write("hello") }
    /// Binding has the lifetime of the body block. Equivalent to Python's
    /// `with` or C# `using`.
    /// Node: ContextBindingStmt with value + binding *ParamDecl + body.
    ContextBindingStmt,

    /// Destructuring binding declaration:
    ///   var (x, y) = expr
    ///   const (a, b, c) = tuple_expr
    /// LHS arity must match the RHS tuple/struct arity.
    /// Node: DestructuringDeclStmt with pattern + value + is_const.
    DestructuringDeclStmt,

    /// Inline foreign block:
    ///   inline "asm" { ... }
    ///   inline "c" { ... }
    ///   inline "c++" { ... }
    /// Body is opaque to the Kairo parser handed off to the foreign
    /// backend lexer/parser unmodified.
    /// Node: InlineBlockStmt with lang Token + raw body span.
    InlineBlockStmt,

    // -----------------------------------------------------------------------
    //  Compile-time blocks
    // -----------------------------------------------------------------------

    /// Eval block (decl-only):  eval { decl* }
    /// Wraps one or more declarations that must be const-evaluable. Sema
    /// errors if any statement appears inside (parser still recovers).
    /// Note: `eval if`, `eval for`, `eval var` are handled by their
    /// respective stmts/decls with `is_eval = true`, not by this kind.
    /// Node: EvalBlockStmt with body FrozenList<*Decl>.
    EvalBlockStmt,

    // -----------------------------------------------------------------------
    //  Marker
    // -----------------------------------------------------------------------
    StmtKindCount,
}