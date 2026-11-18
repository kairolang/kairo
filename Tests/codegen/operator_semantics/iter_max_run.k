// OperatorSemantics: IterLowering's index steps are `no_wrap` (C++'s own
// `++`, whose overflow is UB), which is sound only because no loop steps
// at its bound. Each loop here ends at its type's maximum (or starts at its
// minimum): a `++` at the bound would wrap and loop forever, or be UB that
// clang may turn into anything, so the run is under a timeout and every
// count and last value is checked.

import std::io::*

fn main() -> i32 {
    var n: i32 = 0
    var last: u8 = 0
    for i in 250u8..=255u8 { n += 1; last = i }
    println(f"u8 {n} {last}")                         // U8: u8 6 255

    var m: i32 = 0
    var l2: i32 = 0
    for j in 2147483640..=2147483647 { m += 1; l2 = j }
    println(f"i32 {m} {l2}")                          // I32: i32 8 2147483647

    var k: i32 = 0
    for j in 2147483640..2147483647 { k += 1 }
    println(f"excl {k}")                              // EXCL: excl 7

    var w: i32 = 0
    var lw: u64 = 0
    for j in 18446744073709551613u64..=18446744073709551615u64 { w += 1; lw = j }
    println(f"u64 {w} {lw}")                          // U64: u64 3 18446744073709551615

    var all: i32 = 0
    var lo: i8 = 0
    var a: i8 = -128
    var b: i8 = 127
    for j in a..=b { all += 1; lo = j }
    println(f"i8 {all} {lo}")                         // I8: i8 256 127

    // A Range value: `last` is `hi - 1` only when exclusive and non-empty.
    var r = 2147483645..=2147483647
    var q: i32 = 0
    for j in r { q += 1 }
    println(f"rv {q}")                                // RV: rv 3
    var mn: i32 = -2147483647 - 1
    var r2 = mn..mn
    var e: i32 = 0
    for j in r2 { e += 1 }
    var r3 = mn..(mn + 2)
    var f: i32 = 0
    for j in r3 { f += 1 }
    println(f"min {e} {f}")                           // MIN: min 0 2
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d
// RUN: timeout 20 %t.exe > %t.out; test $? -eq 0
// RUN: %FileCheck %s --check-prefixes=U8,I32,EXCL,U64,I8,RV,MIN --input-file=%t.out
