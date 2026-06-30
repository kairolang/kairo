/// --- The Kairo Project ----------------------- AST/Kind/PatternKind.k --- ///
///
///   Discriminator enum for all pattern-position AST nodes.
///
///   Recovery (error) nodes set kind = RecoveryPattern and store the intended
///   PatternKind in recovery_kind, mirroring the Expr/Stmt/Decl/Type contract.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

enum PatternKind derives u8 {
    // -- Sentinel --------------------------------------------------------
    /// Parser error sentinel. recovery_kind holds the intended kind.
    RecoveryPattern = 0,

    // -- Leaf patterns ---------------------------------------------------
    /// Wildcard:  _
    WildcardPattern,

    /// Literal value:  1 | "foo" | true | null | 'a'
    LiteralPattern,

    /// Name binding:  var x | const x | var x: i32
    /// Carries the explicit-type case too (no separate TypeAscribed kind).
    BindingPattern,

    // -- Composite patterns ----------------------------------------------
    /// Tuple destructure:  (p, p, ...)   no path head, unambiguous.
    TupleDestructurePattern,

    /// Constructor with a RESOLVED path head:  Foo(p, ...) | Foo<T>(p, ...)
    /// | .Variant(p, ...) | Kind::Variant(p, ...). Covers both enum-variant
    /// and struct destructure; sema splits on the resolved decl. Set when the
    /// hoisted lookup hits (or for the dotted form, which is always a variant).
    ConstructorPattern,

    /// Constructor whose path head MISSED the hoisted lookup. Distinct kind so
    /// sema walks a single "resolve-or-error" path instead of re-deriving the
    /// hit/miss split. Never produced for the dotted form (dotted is always a
    /// ConstructorPattern: it needs no lookup).
    UnresolvedConstructorPattern,

    /// Alternation (or-pattern):  1 | 2 | 3  (top-level comma in a case)
    AlternationPattern,

    /// Range:  1..10 | 'a'..='z'   bounds are *Expr, sema enforces const.
    RangePattern,

    /// Slice destructure:  [first, ..rest] | [a, b, ..] | [.., last]
    SlicePattern,

    // -- Marker ----------------------------------------------------------
    PatternKindCount,
}