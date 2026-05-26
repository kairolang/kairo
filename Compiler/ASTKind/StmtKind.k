/// --- The Kairo Project ----------------------------------- <filename> --- ///
///
///   <short description>
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
///   Ranges:
///     Error sentinel
///     Structural statements
///     Jump / signal statements
///     Control-flow statements
///     Exception handling
///     Scope / context modifiers
///     Module-level statements
///
enum StmtKind derives u8 {
    // -----------------------------------------------------------------------
    //  Sentinel
    // -----------------------------------------------------------------------

    /// Parser error sentinel.  Carries the bad source range.
    RecoveryStmt = 0,

    // -----------------------------------------------------------------------
    //  Structural statements  [1 .. 3]
    // -----------------------------------------------------------------------

    /// Compound statement / block:  { stmt* }
    /// Node: CompoundStmt arena array of Stmt*.
    CompoundStmt,

    /// Expression used as a statement:  expr ;
    /// Node: ExpressionStmt wraps an Expr*.
    ExpressionStmt,

    /// A declaration appearing at statement scope:
    ///   var x: i32 = 1;
    ///   fn local() { }
    ///   class Local { }
    /// Node: DeclStmt wraps a Decl*.
    DeclStmt,

    // -----------------------------------------------------------------------
    //  Jump / signal statements  [4 .. 9]
    // -----------------------------------------------------------------------

    /// Return from current function:  return | return expr
    /// Node: ReturnStmt optional value Expr*.
    ReturnStmt,

    /// Break out of a loop or match:  break | break label
    /// Node: BreakStmt optional label Token.
    BreakStmt,

    /// Continue to next loop iteration:  continue | continue label
    /// Node: ContinueStmt optional label Token.
    ContinueStmt,

    /// Raise a panic / abort:  panic expr
    /// Node: PanicStmt message Expr*.
    PanicStmt,

    /// Yield a value from a coroutine:  yield expr
    /// Node: YieldStmt value Expr*.
    YieldStmt,

    /// Runtime assertion:  assert expr, "message"
    /// Node: RuntimeAssertStmt condition + message LiteralExpr*.
    RuntimeAssertStmt,

    /// Compile-time assertion:  assert static expr, "message"
    /// Node: StaticAssertStmt condition (must be const-eval) + message.
    StaticAssertStmt,

    /// Goto statement:  goto label
    /// Node: GotoStmt target label Token.
    GotoStmt,

    // -----------------------------------------------------------------------
    //  Control-flow statements  [10 .. 15]
    // -----------------------------------------------------------------------

    /// Conditional statement:  if expr block  (else block)?
    /// Node: ConditionalStmt cond + then_ + else_ (nullable).
    ConditionalStmt,

    /// While loop:  while expr block
    /// Node: WhileLoopStmt cond + body CompoundStmt*.
    WhileLoopStmt,

    /// Range-based for loop (Python style):
    ///   for x in expr { }
    ///   eval for x in expr { }   compile-time unroll
    /// Node: RangedForStmt bindings + iterable + body + is_eval.
    RangedForStmt,

    /// C-style for loop:
    ///   for (init; cond; update) { }
    ///   eval for (init; cond; update) { }
    /// Node: IndexedForStmt init + cond + update + body + is_eval.
    IndexedForStmt,

    /// Pattern match statement:  match expr { case* }
    /// Node: PatternMatchStmt scrutinee + MatchCase array.
    PatternMatchStmt,

    // Labeled statement wrapper: loop_name: while true { }
    // Node carries label token + inner Stmt*
    LabeledStmt,

    /// Delete statement (heap deallocation used as a statement):
    ///   delete expr | delete[] expr
    /// Note: delete as an *expression* is DeleteExpr.
    ///       As a statement it wraps DeleteExpr in ExpressionStmt.
    ///       This variant exists for clarity in the visitor.
    /// Node: ExpressionStmt wrapping DeleteExpr no separate StmtKind needed.
    /// (intentionally omitted handled by ExpressionStmt)

    // -----------------------------------------------------------------------
    //  Exception handling  [14 .. 16]
    // -----------------------------------------------------------------------

    /// Try / catch / finally block:
    ///   try { } catch e { } catch { } finally { }
    /// Node: TryCatchStmt try body + CatchArm array + optional finally body.
    TryCatchStmt,

    /// Standalone finally block (also appears inside TryCatchStmt):
    ///   finally { }
    /// Node: FinallyStmt body CompoundStmt*.
    FinallyStmt,

    /// Unsafe block:  unsafe { }
    /// Introduces an UnsafeContext DeclContext.
    /// Node: UnsafeBlockStmt body CompoundStmt*.
    UnsafeBlockStmt,

    // -----------------------------------------------------------------------
    //  Scope / context modifiers  [17 .. 18]
    // -----------------------------------------------------------------------

    /// Context / with statement:  expr as binding block
    ///   file as f { f.write("hello") }
    /// Node: ContextBindingStmt value + binding ParamDecl* + body.
    ContextBindingStmt,

    /// Destructuring binding in assignment or declaration:
    ///   var (x, y) = expr
    ///   const (a, b, c) = tuple_expr
    /// Node: DestructuringDeclStmt pattern + value + is_const flag.
    DestructuringDeclStmt,

    // Inline foreign block (statement position)
    // inline "asm" { } | inline "c" { } | inline "c++" { }
    InlineBlockStmt,

    // -----------------------------------------------------------------------
    //  Module-level statements  [19 .. 20]
    // -----------------------------------------------------------------------

    /// Import statement (single or multi):
    ///   import foo::bar;
    ///   import foo::bar as baz;
    ///   import { foo::bar, baz::* };
    ///   ffi "c++" import "stdio.h";
    /// Node: ImportDeclStmt ImportItem array + optional ffi lang tag.
    ImportDeclStmt,

    /// FFI block statement:  ffi "c++" { imports }
    /// Introduces an FFIContext DeclContext with the given language tag.
    /// Node: FFIBlockStmt lang tag + body ImportDeclStmt*.
    FFIBlockStmt,

    // Eval block: eval { stmt* }
    // Sema errors if contents are not const-evaluable
    EvalBlockStmt,

    // -----------------------------------------------------------------------
    //  Marker
    // -----------------------------------------------------------------------
    StmtKindCount,
}