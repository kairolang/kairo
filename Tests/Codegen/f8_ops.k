// `f8e4m3` and `f8e5m2` compile. C++ spells the types as
// `::kairo::rt::f8e4m3` and so on; they are
// std/rt/Float8.k's
// F8E4M3 / F8E5M2 classes, loaded into the files that spell the types
// as f256's class is: a literal is its encoding rounded once from the
// digits at compile time (1000.0 saturates to 448 in the finite-only E4M3),
// arithmetic rounds the f32 result once, `as` converts both ways with every
// float and integer, a limit is the class, and `{x}` prints the shortest
// digits that read back as the same encoding (rt's kairo_rt_fmt_f8*).

import std::io
import std::rt::Float8::{
    F8E4M3,
    F8E5M2,
}

struct Pair {
    var a: f8e5m2 = 1.0
    var b: [f8e4m3; 2] = [0.5, 0.25]
}

fn twice(x: f8e4m3) -> f8e4m3 { return x + x }

fn main() -> i32 {
    // Every encoding of both formats to f32 and back, and OCP's named ones.
    io::println(f"agree {F8E4M3::verify_()} {F8E5M2::verify_()}")

    var a: f8e4m3 = 1.5
    var b: f8e4m3 = 2.25
    var c = a * b               // 3.375 ties to even: 3.5
    var d: f8e5m2 = 3.0
    io::println(f"ops {c} {d + d} {-a} {b - a} {b / a} {twice(c)}")
    a += b                      // 3.75
    io::println(f"assign {a}")

    var big: f8e4m3 = 1000.0    // saturates: E4M3FN has no infinity
    var huge: f8e5m2 = 1.0e9    // E5M2 has one
    var tiny: f8e4m3 = 0.001953125
    io::println(f"range {big} {huge} {tiny} {big == f8e4m3::MAX}")

    io::println(f"to {c as f32} {c as f64} {c as i32} {(-c) as i8} {c as u8}")
    io::println(f"from {7 as f8e4m3} {d as f8e4m3} {c as f8e5m2} {(0.1 as f32) as f8e4m3}")

    var n = f8e4m3::NAN
    var z: f8e4m3 = -0.0
    io::println(f"cmp {c < a} {a <= a} {n == n} {n != n} {z == 0.0}")
    io::println(f"limits {f8e4m3::MAX} {f8e5m2::MAX} {f8e5m2::INFINITY} {f8e4m3::MIN_POSITIVE} {f8e4m3::EPSILON}")
    io::println(f"fmt {c:.3e} {c:8.2}| {z} {n}")

    var p = Pair()
    io::println(f"field {p.a} {p.b[1]}")
    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --match-full-lines < %t.out
// CHECK:      agree true true
// CHECK-NEXT: ops 3.5 6 -1.5 0.75 1.5 7
// CHECK-NEXT: assign 3.8
// CHECK-NEXT: range 450 inf 0.002 true
// CHECK-NEXT: to 3.5 3.5 3 -3 3
// CHECK-NEXT: from 7 3 3.5 0.1
// CHECK-NEXT: cmp true true false true true
// CHECK-NEXT: limits 450 6e+04 inf 0.016 0.13
// CHECK-NEXT: fmt 3.500e+00      3.5| -0 nan
// CHECK-NEXT: field 1 0.25
