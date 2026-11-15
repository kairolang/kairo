/// --- The Kairo Project ---------------------------- Lib/std/utility.k --- ///
///
///   Explicit value transfer: `move`, re-exported at the std root as
///   `std::move`.
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
/// \param x  the value to move out
/// \returns the value `x` held
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
