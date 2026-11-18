// XFAIL: *
// Defect (compiler): a negative decimal literal whose magnitude is wider than 64 bits (and narrower than 128), assigned
// to an i256 or i512, is zero-extended instead of sign-extended: `var a: i256 = -18446744073709551616` holds
// 340282366920938463444927863358058659840 (2^128 - 2^64), and `-170141183460469231731687303715884105728` holds
// +2^127. Negating a variable (`0 - p`, `-p`) and widening an i128 with `as` give the right value, so only the
// literal is wrong. language/primitives.mdx lists i256 and i512 as ordinary signed integers; the same literal in an
// i128 is correct.
// Smallest reproducer: the first case below.

import std::io::*

var CODE: i32 = 0

fn ck(const got: string, const want: string, id: i32, const name: string) {
    if !(got == want) {
        println(f"FAIL {name}: got [{got}] want [{want}]")
        if CODE == 0 {
            CODE = id
        }
    }
}

fn main() -> i32 {
    var a: i256 = -18446744073709551616
    var b: i256 = -170141183460469231731687303715884105728
    var c: i256 = -1000000000000000000000000000000
    var d: i512 = -18446744073709551616
    var e: i512 = -170141183460469231731687303715884105728
    var f: i128 = -18446744073709551616
    ck(f"{f}", "-18446744073709551616", 1, "i128 literal (control)")
    ck(f"{a}", "-18446744073709551616", 2, "i256 -(2^64)")
    ck(f"{b}", "-170141183460469231731687303715884105728", 3, "i256 -(2^127)")
    ck(f"{c}", "-1000000000000000000000000000000", 4, "i256 -(10^30)")
    ck(f"{d}", "-18446744073709551616", 5, "i512 -(2^64)")
    ck(f"{e}", "-170141183460469231731687303715884105728", 6, "i512 -(2^127)")
    if CODE == 0 {
        println("ok")
    }

    return CODE
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: ok
