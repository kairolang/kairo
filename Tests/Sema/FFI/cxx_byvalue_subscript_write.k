// A C++ `operator[]` that returns by value gives a temporary, as a
// call does, so writing to `c[0]` is the ordinary not-assignable error.
// The result was typed as an lvalue: `c[0] = 2` converted 2 to the
// element struct (SC028E "cannot convert 'i32' to 'P952Tag'"), and every
// same-typed write, `&c[0]`, `+=` and `++` passed Sema. A reference result
// stays a place, and reads and method calls on a temporary are fine.
ffi "c++" import "Inputs/p952_byvalue_subscript.h"

fn main() -> i32 {
    const c = P952Box()
    var n = P952Int()
    var r = P952Ref()
    var t: P952Tag = c[0]

    c[0] = 2
// DIAG: cxx_byvalue_subscript_write.k:[[@LINE-1]]:5: error [SC071E]: left side of assignment is not assignable
    c[0] = t
// DIAG: cxx_byvalue_subscript_write.k:[[@LINE-1]]:5: error [SC071E]: left side of assignment is not assignable
    var p = &n[0]
// DIAG: cxx_byvalue_subscript_write.k:[[@LINE-1]]:13: error [SC069E]: cannot take the address of a temporary
    n[0] = 2
// DIAG: cxx_byvalue_subscript_write.k:[[@LINE-1]]:5: error [SC071E]: left side of assignment is not assignable
    n[0] += 1
// DIAG: cxx_byvalue_subscript_write.k:[[@LINE-1]]:5: error [SC071E]: left side of assignment is not assignable
    ++n[0]
// DIAG: cxx_byvalue_subscript_write.k:[[@LINE-1]]:5: error [SC071E]: '++'/'--' require an assignable operand

    // fine: reads, a method call on the temporary, a reference result
    var k: i32 = n[0] + c[0].v
    var b = c[0].bump()
    r[0] = 9
    r[0] += 1
    return k + b + t.v
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
