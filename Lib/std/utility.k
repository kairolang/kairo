/// --- The Kairo Project ---------------------------- Lib/std/utility.k --- ///
///
///   Explicit value transfer: `move` and `copy`, re-exported at the std
///   root as `std::move` and `std::copy`.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// Moves `x` out and returns it.
///
/// `x` is taken by a `@move` parameter, so the argument is moved-from after the call exactly
/// as if it had been passed to any `@move` parameter: a later use of it is a compile error
/// until it is assigned again. That holds for every type, a COPY type and a primitive
/// included, because a generic `@move` parameter always consumes its argument. The argument
/// may be a local, a parameter, a field (`std::move(self.name)`, `std::move(p->a)`), `*p` or
/// an element (`std::move(v[0])`, which leaves the whole container moved-from).
///
/// The result is built by one move construction from `x`; `var y = std::move(x)` constructs
/// `y` in place from it, with no further move or copy.
///
/// ### Parameters
/// - `x`: the value to move out
///
/// ### Returns
/// the value `x` held
/// \example
/// ```kairo
/// import std
///
/// var a = UniqueFile()
/// var b = std::move(a)   // a is moved-from
/// a = UniqueFile()       // a is usable again
/// ```
pub fn <T> move(@move x: T) -> T {
    return x
}

/// A type that makes its copies itself: what `copy` calls when it is declared.
priv interface CopiesItself {
    fn copy(const self) -> Self
}

/// A type with a copy constructor (every COPY class, every primitive and pointer).
priv interface Copy {
    @copy
    fn Copy(self, const other: Self)
}

/// Returns a copy of `x`, leaving `x` untouched.
///
/// A type that declares `fn copy(const self) -> Self` is copied by that method, written
/// for the purpose, even when it also has a copy constructor. Any other type is copied by
/// its copy constructor: every COPY class, every primitive and every pointer. A type with
/// neither, such as a move-only class with no `copy()`, is a compile error naming both
/// ways to make it copyable.
///
/// ### Parameters
/// - `x`: the value to copy; it is borrowed, so it stays usable after the call
///
/// ### Returns
/// a new value equal to `x`
/// \example
/// ```kairo
/// import std
///
/// var a = Config(4)
/// var b = std::copy(a)   // a is still usable
/// ```
pub fn <T> copy(const x: T) -> T requires T impl CopiesItself {
    return x.copy()
}

/// The copy-constructor case of `copy`; see above.
pub fn <T> copy(const x: T) -> T requires T impl Copy && !(T impl CopiesItself) {
    return x
}
