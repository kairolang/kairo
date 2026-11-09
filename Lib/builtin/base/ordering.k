/// --- The Kairo Project ------------------ Lib/builtin/base/ordering.k --- ///
///
///   The Ordering lang item: what a three-way comparison answers.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// The result of a three-way comparison: what `a <=> b` evaluates to.
///
/// The discriminants are -1, 0 and 1. The relational operators are lowered from `op <=>`:
/// `a < b` becomes `((a.op<=>(b)) as i8) < 0`, with the original token compared against 0.
///
/// \example
/// ```kairo
/// struct Version { var major: i32 }
///
/// extend Version {
///     fn op <=>(const self, const other: Version) -> Ordering {
///         if self.major < other.major { return Ordering::Less }
///         if self.major > other.major { return Ordering::Greater }
///         return Ordering::Equal
///     }
/// }
///
/// fn main() -> i32 {
///     var a = Version { major: 1 }
///     var b = Version { major: 2 }
///     if (a <=> b) == Ordering::Less { return 0 }
///     return 1
/// }
/// ```
pub enum Ordering derives i8 {
    /// The left operand orders before the right (-1).
    Less    = -1,
    /// The operands are equivalent (0).
    Equal   = 0,
    /// The left operand orders after the right (1).
    Greater = 1,
}
