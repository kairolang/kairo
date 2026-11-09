// `typeof e` in a type position is the type `var y = e` would infer
// for that variable (type-system.mdx, "Typeof Identity Semantics"). It used
// to crash twice over: the operand was parsed as a whole expression, so
// `var y: typeof x = 100` was `typeof (x = 100)` with no initializer, and
// the type never got a canonical, so codegen met an unresolved type.
//
// What is asserted here: the initializer is the declaration's, the written
// type wins over the initializer's own (`var h: typeof d = 1` is an f64,
// so `h / 2` is 0.5, not 0), a declaration with no initializer works, a
// file-scope variable can be typed from one declared later, and a
// nullable operand gives the nullable.

var late_g: typeof early_g = 7
var early_g: i64 = 1

fn main() -> i32 {
    var x = 42
    var y: typeof x = 100
    if y - x != 58 { return 1 }

    var d: f64 = 2.0
    var h: typeof d = 1
    if h / 2 != 0.5 { return 2 }

    var z: typeof x
    z = 5
    if z != 5 { return 3 }

    if late_g + early_g != 8 { return 5 }

    var m: i32? = null
    var n: typeof m = null
    if n? { return 6 }
    n = 3
    if (n ?? 0) != 3 { return 7 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
