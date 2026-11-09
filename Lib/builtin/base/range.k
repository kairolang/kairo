/// --- The Kairo Project --------------------- Lib/builtin/base/range.k --- ///
///
///   The range lang items: `a..b` / `a..=b` is Range, `a..` (and `..`)
///   RangeFrom, `..b` / `..=b` RangeTo.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// A bounded range: `a..b` (exclusive end) and `a..=b` (inclusive end).
///
/// Field order is evaluation order: RangeLowering builds a range as a designated initializer, and
/// C++ evaluates those in declaration order, so `f()..g()` runs `f` first. Keep `begin` before
/// `end`. A `for` loop over a range is lowered to a counting loop directly and never builds one.
///
/// \example
/// ```kairo
/// fn main() -> i32 {
///     var sum = 0
///     for i in 0..4 { sum += i }
///     return sum - 6
/// }
/// ```
pub struct <T> Range {
    /// The first value of the range.
    var begin:     T
    /// The end value; excluded unless `inclusive` is set.
    var end:       T
    /// True for `a..=b`, false for `a..b`.
    var inclusive: bool
}

/// A range with no end: `a..`, or `..` as `begin: 0` (a `RangeFrom<usize>`).
///
/// Only valid as a subscript index, such as `v[2..]`.
pub struct <T> RangeFrom {
    /// The first index of the range.
    var begin: T
}

/// A range with no start: `..b` or `..=b`.
///
/// Only valid as a subscript index, such as `v[..3]`.
pub struct <T> RangeTo {
    /// The end index; excluded unless `inclusive` is set.
    var end:       T
    /// True for `..=b`, false for `..b`.
    var inclusive: bool
}
