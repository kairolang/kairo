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

enum PatternKind {
    // -----------------------------------------------------------------------
    //  Sentinel
    // -----------------------------------------------------------------------

    /// Parser error sentinel.
    RecoveryPattern = 0, // parser error sentinel

    /// Wildcard / default:  _ | default
    WildcardPattern = 0,

    /// Literal value match:  1 | "foo" | true | null
    LiteralPattern,

    /// Name binding:  var x | const x
    BindingPattern,

    /// Struct / class field destructure:  Point { x: 1, y: var y }
    StructDestructurePattern,

    /// Tuple destructure:  (var x, var y)
    TupleDestructurePattern,

    /// Enum variant match:  Direction::North | Option::Some(var x)
    EnumVariantPattern,

    /// Alternation (or-pattern):  1 | 2 | 3
    AlternationPattern,

    /// Guard pattern:  var x if x > 5
    GuardedPattern,

    /// Range pattern:  1..10 | 'a'..='z'
    RangePattern,

    // Slice destructure pattern: [first, ..rest] | [a, b, ..] | [.., last]
    SlicePattern,

    // Type-ascribed binding: var x: i32 (binding with explicit type check)
    TypeAscribedBindingPattern,

    PatternKindCount,
}