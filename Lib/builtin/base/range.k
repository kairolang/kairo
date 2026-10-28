/// --- The Kairo Project --------------------- Lib/builtin/base/range.k --- ///
///
///   The range lang items: `a..b` / `a..=b` is Range, `a..` (and `..`)
///   RangeFrom, `..b` / `..=b` RangeTo.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// `a..b` / `a..=b`. Field order is evaluation order: RangeLowering builds a
/// range as a designated initializer, and C++ evaluates those in declaration
/// order. Keep `begin` before `end`.
pub struct <T> Range {
    var begin:     T
    var end:       T
    var inclusive: bool
}

/// `a..`, and `..` as `begin: 0`. Only valid as a subscript index.
pub struct <T> RangeFrom {
    var begin: T
}

/// `..b` / `..=b`. Only valid as a subscript index.
pub struct <T> RangeTo {
    var end:       T
    var inclusive: bool
}
