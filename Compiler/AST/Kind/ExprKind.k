/// --- The Kairo Project -------------------------- AST/Kind/ExprKind.k --- ///
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
///   ExprKind
///
///   Layout:
///     Error sentinel
///     Scalar literals
///     Collection literals
///     Initializer expressions
///     Name / path / postfix expressions
///     Operator expressions
///     Type relation expressions
///     Control-flow expressions
///     Lambda / closure
///     Async / concurrency expressions
///     Intrinsic / builtin expressions
///     Memory / lifetime expressions
///     Variadic pack expressions
///     Type cast
///     Sema-inserted expressions
///

enum ExprKind derives u8 {
    // -----------------------------------------------------------------------
    //  Sentinel
    // -----------------------------------------------------------------------

    /// Produced by the parser on a syntax error. Carries the bad source
    /// range. Sema skips any node whose kind is RecoveryExpr.
    /// `recovery_kind` on the Expr base stores what we were trying to parse.
    RecoveryExpr = 0,

    // -----------------------------------------------------------------------
    //  Scalar literals  [1 .. 6]
    // -----------------------------------------------------------------------

    /// Integer literal: 42 | 0xFF | 0b1010 | 0o77 | 1_000_000
    /// Node: IntegerLiteralExpr: token + numeric suffix type.
    IntegerLiteralExpr,

    /// Floating-point literal: 1.2 | 1.2e-3 | 0x1.8p+1 | .5f32
    /// Node: FloatingLiteralExpr: token + fp suffix type.
    FloatingLiteralExpr,

    /// String literal (plain, raw, or format):
    ///   "hello"        plain
    ///   r"raw \n"      raw (no escape processing)
    ///   f"hi {name}!"  format string (carries interpolation exprs)
    /// Node: StringLiteralExpr: StringLiteralKind sub-enum inside node.
    StringLiteralExpr,

    /// Character literal: 'a' | '\n' | '\u{1F600}'
    /// Node: CharacterLiteralExpr: codepoint value + encoding.
    CharacterLiteralExpr,

    /// Boolean literal: true | false
    /// Node: BooleanLiteralExpr
    BooleanLiteralExpr,

    /// Null literal: null | &null (null pointer / nullable null)
    /// Node: NullLiteralExpr: is_ref flag distinguishes &null.
    NullLiteralExpr,

    // -----------------------------------------------------------------------
    //  Collection literals  [7 .. 10]
    // -----------------------------------------------------------------------

    /// Array literal: [1, 2, 3]
    /// Node: ListLiteralExpr
    ListLiteralExpr,

    /// Tuple literal: (1, "two", 3.0)
    /// Node: TupleLiteralExpr
    TupleLiteralExpr,

    /// Set literal: {1, 2, 3}
    /// Node: SetLiteralExpr
    SetLiteralExpr,

    /// Map literal: {"key": value, "other": value2}
    /// Node: MapLiteralExpr: stores key-value pairs.
    MapLiteralExpr,

    // -----------------------------------------------------------------------
    //  Initializer expressions  [11 .. 12]
    //
    //  Distinguished from literals: initializers describe a type's storage
    //  layout rather than a value sequence.
    // -----------------------------------------------------------------------

    /// Named (typed) struct/class initializer: Point { x: 1, y: 2 }
    /// Node: NamedInitializerExpr: type path + field list.
    NamedInitializerExpr,

    /// Anonymous (dot-prefixed) struct initializer: { .x: 1, .y: 2 }
    /// Node: AnonInitializerExpr: no type path, sema infers from context.
    AnonInitializerExpr,

    // -----------------------------------------------------------------------
    //  Name / path / postfix expressions  [13 .. 17]
    // -----------------------------------------------------------------------

    /// Pure access chain. Covers:
    ///   - field access:           foo.bar.baz
    ///   - scope resolution:       foo::bar::baz
    ///   - generic instantiation:  foo::bar::<T, U>
    ///   - safe-navigation:        foo?.bar
    ///   - pointer member access:  foo->bar, foo->*bar
    ///   - global-root path:       ::std::print
    ///
    /// No calls, no subscripts those are separate nodes that wrap this.
    /// base: *Expr + steps: FrozenList<Step> where each step carries an
    /// access kind, identifier, and optional generic args.
    ///
    /// Node: ChainExpr
    ChainExpr,

    /// Function / method / constructor call: expr(args)
    /// Callee is any expression: NamedIdentExpr, ChainExpr, GroupingExpr,
    /// another CallExpr (for chained calls like get_fn()(x)), etc.
    ///
    /// Node: CallExpr: callee: *Expr + args: FrozenList<*Expr>
    CallExpr,

    /// Subscript / index / slice:
    ///   element access:  arr[i]
    ///   slice:           arr[1..3] | arr[..3] | arr[1..]
    /// Base is any expression.
    ///
    /// Node: SubscriptExpr: base: *Expr + index: *Expr (RangeExpr for slices)
    SubscriptExpr,

    /// Single identifier with optional generic args:
    ///   foo           bare identifier
    ///   Bar<i32>      generic instantiation on a bare name
    ///
    /// `self` is also represented as a NamedIdentExpr sema identifies
    /// it by name during resolution. No dedicated SelfExpr node.
    ///
    /// Node: NamedIdentExpr: name: Token + generic_args: FrozenList<GenericArg>
    NamedIdentExpr,

    // -----------------------------------------------------------------------
    //  Operator expressions  [18 .. 20]
    // -----------------------------------------------------------------------

    /// Unary prefix or postfix operator:
    ///   prefix:   ++x | --x | !x | -x | ~x | &x | *x | delete x
    ///   postfix:  x++ | x-- | x? | x...
    /// Node: UnaryOperatorExpr: Fix (Pre/Post) + operator token + operand.
    UnaryOperatorExpr,

    /// Binary infix operator:
    ///   arithmetic:   x + y | x - y | x * y | x / y | x % y | x ** y
    ///   bitwise:      x & y | x | y | x ^ y | x << y | x >> y
    ///   logical:      x && y | x || y
    ///   comparison:   x == y | x != y | x < y | x > y | x <= y | x >= y
    ///   identity:     x === y (referential equality)
    ///   range:        x .. y | x ..= y (see also RangeExpr)
    /// Node: BinaryOperatorExpr: operator token + lhs + rhs.
    BinaryOperatorExpr,

    /// Assignment operator: = | += | -= | *= | /= | %= | **= | &= | |= | ^= | <<= | >>=
    /// Distinct from BinaryOperatorExpr to simplify visitor handling and
    /// precedence parsing. Right-associative.
    /// Node: AssignOperatorExpr: operator token + lhs + rhs.
    AssignOperatorExpr,

    // -----------------------------------------------------------------------
    //  Type-relation expressions  [21 .. 22]
    //
    //  Produce bool. Appear in requires clauses and conditions.
    // -----------------------------------------------------------------------

    /// Interface conformance test: T impl Interface
    /// Node: ImplConformanceExpr: lhs type + interface type.
    ImplConformanceExpr,

    /// Inheritance / derivation test: T derives Base
    /// Node: DerivesRelationExpr: lhs type + base type.
    DerivesRelationExpr,

    // -----------------------------------------------------------------------
    //  Control-flow expressions  [23 .. 26]
    //
    //  All produce values. Sema enforces branch type compatibility.
    // -----------------------------------------------------------------------

    /// If expression (block form): if cond { expr } else { expr }
    /// Requires else branch: sema error if absent.
    /// Node: IfExpr
    IfExpr,

    /// try-catch expression: try: expr catch e: fallback
    /// Node: InlineTryCatchExpr: try_expr + catch arms.
    TryCatchExpr,

    /// Match expression: match scrutinee { arms }
    /// Node: MatchExpr: scrutinee + cases.
    MatchExpr,

    /// Range expression: x..y | x..=y | ..y | x.. | ..
    /// Node: RangeExpr: begin (nullable) + end (nullable) + is_inclusive.
    RangeExpr,

    // -----------------------------------------------------------------------
    //  Lambda / closure  [27]
    // -----------------------------------------------------------------------

    /// Anonymous function expression:
    ///   fn <T> (x: T, y: i32)|foo| -> i32 { x + y + foo }
    ///   fn (x: i32) { std::print(x) }   inferred void return
    /// Node: ClosureExpr: params + optional generics + captures + return type + body.
    ClosureExpr,

    // -----------------------------------------------------------------------
    //  Async / concurrency expressions  [28 .. 30]
    // -----------------------------------------------------------------------

    /// Suspend current async task and await a future: await expr
    /// Node: AwaitExpr: operand: *Expr
    AwaitExpr,

    /// Spawn a new async task: spawn expr
    /// Node: SpawnExpr: operand: *Expr
    SpawnExpr,

    /// Spawn an OS thread: thread expr
    /// Node: ThreadExpr: operand: *Expr
    ThreadExpr,

    // -----------------------------------------------------------------------
    //  Intrinsic / builtin expressions  [31 .. 35]
    // -----------------------------------------------------------------------

    /// Type conformance constraint: T impl Foo | T derives Base.
    /// Node: ConstraintExpr: lhs type, op (impl/derives), rhs type. A bool-
    /// typed compile-time predicate, valid only in requires clauses. Sema
    /// partitions these out of a requires conjunction as conformance
    /// constraints (feeding the bound table) vs value predicates.
    ConstraintExpr,

    /// Size of a type in bytes: sizeof T | sizeof(T)
    /// Node: SizeOfExpr: type operand.
    SizeOfExpr,

    /// Alignment of a type in bytes: alignof T | alignof(T)
    /// Node: AlignOfExpr: type operand.
    AlignOfExpr,

    /// Type of an expression: typeof expr | typeof(expr)
    /// Node: TypeOfExpr: expr operand.
    TypeOfExpr,

    /// Eval-qualified expression: eval expr
    /// Forces compile-time evaluation of the wrapped expr.
    /// Node: EvalExpr: operand: *Expr
    EvalExpr,

    /// Unsafe expression: unsafe expr
    /// Permits otherwise-restricted operations within the operand.
    /// Node: UnsafeExpr: operand: *Expr
    UnsafeExpr,

    // -----------------------------------------------------------------------
    //  Memory / lifetime expressions  [36]
    // -----------------------------------------------------------------------

    /// Explicit heap deallocation: delete expr | delete [expr]
    /// Node: DeleteExpr: operand: *Expr + is_array: bool
    DeleteExpr,

    // -----------------------------------------------------------------------
    //  Variadic pack expressions  [37]
    // -----------------------------------------------------------------------

    /// Variadic unpack expansion: foo...
    /// Node: PackExpansionExpr: operand: *Expr
    PackExpansionExpr,

    // -----------------------------------------------------------------------
    //  Type cast  [38]
    // -----------------------------------------------------------------------

    /// Explicit type cast: expr as Type
    /// Node: TypeCastExpr: value: *Expr + target: *Type, is_unsafe: bool
    TypeCastExpr,

    // -----------------------------------------------------------------------
    //  Sema-inserted  [39]
    // -----------------------------------------------------------------------

    /// Inserted by sema at FFI call boundaries. Carries:
    ///   original expr + source type + target ABI type
    /// Invisible to the programmer, visible in AST dumps for debugging.
    ImplicitBoundaryCastExpr,

    // -----------------------------------------------------------------------
    //  Marker
    // -----------------------------------------------------------------------
    ExprKindCount,
}