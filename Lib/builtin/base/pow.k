/// --- The Kairo Project ----------------------- Lib/builtin/base/pow.k --- ///
///
///   The Pow lang item: what `^^` on a primitive base calls.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// `^^` on a primitive base. Repeated squaring, so overflow is exactly `*`'s.
/// A negative exponent is `(1 / base) ^^ -exp` under the base type's own
/// division: for an integer base that reciprocal is 0, 1 or -1 and nothing
/// can overflow on the way back; for a float base it is the reciprocal.
/// `-(exp + 1)` rather than `-exp`, which has no value for the minimum.
/// `: type`: B and E are only ever primitives, and no interface says
/// "numeric" yet, so this one body is C++'s to check per instance (MONO.md
/// D1); a bare `<B, E>` would be refused, its operators granted by no bound.
priv fn <B: type, E: type> pow(base: B, exp: E) -> B {
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
