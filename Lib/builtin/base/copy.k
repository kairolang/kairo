/// builtin/base/copy.k

/// The duplication bound. Met by any type that declares copy(), and by every
/// COPY type (primitives, pointers, slices, plain structs) through its copy
/// constructor. string and the owning containers meet it through copy().
pub interface Copyable {
    fn copy(const self) -> Self
}

/// Implicit copies only: `var b = a` leaves both live. The owning builtins
/// do not meet it.
pub interface Copy {
    @copy fn Copy(self, const other: Self)
}

/// Returns a copy of `x`; `x` stays usable.
pub inline fn <T impl Copyable> copy(const x: T) -> T = x.copy()

/// Moves `x` out; the argument is moved-from until it is assigned again.
pub inline fn <T> move(@move x: T) -> T = x
