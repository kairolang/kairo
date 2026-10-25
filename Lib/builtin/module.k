/// --- The Kairo Project ------------------------- Lib/builtin/module.k --- ///
///
///   The builtin root: every declaration sema binds as a lang item. Shipped
///   with the compiler, installed under <resource-dir>/builtin, imported
///   implicitly by every translation unit. Nothing here is user-visible by
///   any name but its own; `[T]`, `{K: V}` and `string` are sugar for it.
///
///   builtin DECLARES; std EXTENDS. A type sema needs a handle to goes here.
///   A method only users call goes in std.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

module builtin

pub import containers::*
pub import string::*
pub import types::*
pub import fmt::*

/// `null` as a value: the type of the constant every null converts from. A
/// C++ host spells the constant `::builtin::null` (InterfaceEmitter writes
/// it after this record; `null` is a Kairo keyword, so it has no Kairo
/// declaration of its own). Empty: a null carries nothing.
pub struct null_t {}

/// `T?`. Kairo code never names it (the `?` suffix is the only spelling);
/// C++ code does. Tagged, Stage 1's only storage (NULLABLE.md 1.2): an ADT,
/// so the payload is a real T only while present, constructed in place and
/// destroyed exactly once, and copy and move follow T's own -- the special
/// members EnumLayoutLowering gives every generic ADT. That pass also gives
/// THIS one, the lang item, the C++ surface the desugars and a C++ host
/// use: `Nullable()` and `Nullable(null_t)` (null), `Nullable(const T&)`
/// and `Nullable(T&&)` (present), `is_null()`, the unchecked `__value()`
/// and `==` when T has one. Every implicit `T -> T?` and `null -> T?` is
/// one of those constructors. Nothing outside this declaration may depend
/// on the layout: the niche storages (G2b) replace it.
pub enum <T> Nullable {
    Value { v: T },
    Null,
}

/// `^^` on a primitive base. Repeated squaring, so overflow is exactly `*`'s.
/// A negative exponent is `(1 / base) ^^ -exp` under the base type's own
/// division: for an integer base that reciprocal is 0, 1 or -1 and nothing
/// can overflow on the way back; for a float base it is the reciprocal.
/// `-(exp + 1)` rather than `-exp`, which has no value for the minimum.
priv fn <B, E> pow(base: B, exp: E) -> B {
    if exp < 0 {
        var inv: B = 1 / base
        return pow(inv, -(exp + 1)) * inv
    }
    var r: B = 1
    var b = base
    var e = exp
    while e > 0 {
        if (e % 2) == 1 { r = r * b }
        b = b * b
        e = e / 2
    }
    return r
}
