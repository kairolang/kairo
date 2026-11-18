// Integer and floating-point arithmetic and formatting give the same results
// on Windows as on the host.

import std::io::println

fn main() -> i32 {
    var s = 0
    for i in 1..101 { s += i }
    println(f"sum {s}")
    var a: i32 = -7
    var b: i32 = 2
    println(f"div {a / b} rem {a % b}")
    var one: i32 = 5
    println(f"shifts {one << 3} {40 >> 3}")
    var big: i64 = 9223372036854775807
    println(f"big {big}")
    var u: u32 = 4294967295
    println(f"unsigned {u}")
    var f: f64 = 1.75
    println(f"float {f * 2.0}")
    var g: f64 = 2.5
    println(f"mul {g * 3.0}")
    var q: f64 = 4.0
    println(f"sqrt-ish {q / 2.0}")
    var h: u64 = 1234567890123
    println(f"fmt {h}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: wine, sysroot-x86_64-windows-gnu
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s --target=x86_64-windows-gnu -o %t.exe --cache-dir %t.d
// RUN: %wine %t.exe | %FileCheck %s --match-full-lines
// CHECK: sum 5050
// CHECK-NEXT: div -3 rem -1
// CHECK-NEXT: shifts 40 5
// CHECK-NEXT: big 9223372036854775807
// CHECK-NEXT: unsigned 4294967295
// CHECK-NEXT: float 3.5
// CHECK-NEXT: mul 7.5
// CHECK-NEXT: sqrt-ish 2
// CHECK-NEXT: fmt 1234567890123
