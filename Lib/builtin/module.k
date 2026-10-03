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



pub import containers::*
pub import string::*
pub import types::*
pub import fmt::*

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
