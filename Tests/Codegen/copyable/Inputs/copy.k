// builtin/base/copy.k as the tests of the Copyable lang item see it: the
// suite adds it to a copy of the builtin tree (lit: %overlay_builtins).

/// The duplication bound. Met by any type that declares copy(), and by every
/// COPY type (primitives, pointers, slices, plain structs) through its copy
/// constructor.
pub interface Copyable {
    fn copy(const self) -> Self
}

/// Implicit copies only: `var b = a` leaves both live.
pub interface Copy {
    @copy fn Copy(self, const other: Self)
}

/// Returns a copy of `x`; `x` stays usable.
pub inline fn <T impl Copyable> copy(const x: T) -> T = x.copy()

/// Moves `x` out; the argument is moved-from until it is assigned again.
pub inline fn <T> move(@move x: T) -> T = x
