/// builtin/base/range.k

import base::c_char::*

/// A foreign string-like value: a pointer to its first char and a byte count.
/// Structural, so nothing declares it: `cxx::std::string`,
/// `cxx::std::string_view`, `cxx::llvm::StringRef` all meet it as they are.
/// It is how `string` takes a C++ string without the library naming one.
pub interface ByteRange {
    fn data(const self) -> unsafe *const __builtin_c_char
    fn size(const self) -> usize
}

/// A foreign contiguous run of `T`: a pointer to the first element and a
/// count. Structural: `cxx::std::vector<T>`, `cxx::std::span<T>`,
/// `cxx::std::array<T, N>`, `cxx::llvm::ArrayRef<T>` and
/// `cxx::llvm::SmallVector<T>` meet it as they are (`std::vector<bool>` has
/// no `data()` and does not).
pub interface <T> ElemRange {
    fn data(const self) -> unsafe *const T
    fn size(const self) -> usize
}

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
    var begin: T
    /// The end value; excluded unless `inclusive` is set.
    var end: T
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
    var end: T
    /// True for `..=b`, false for `..b`.
    var inclusive: bool
}
