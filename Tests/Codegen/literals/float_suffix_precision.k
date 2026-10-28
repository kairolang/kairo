// An f32 literal is rounded once, to f32, by clang (primitives.mdx: the
// suffix fixes the type). 16777217 is 2^24 + 1: the first integer f32
// cannot hold, so as f32 it is 16777216 and as f64 it is exact. 0.1 rounds
// differently at the two widths. bf16 has no C++ literal suffix and goes
// through an f32 literal; its 8-bit mantissa makes 1.00390625 (1 + 2^-8)
// round to 1.

import std::io::println

fn main() -> i32 {
    var r = 0
    var a = 16777217.0f32               // bound first: clang would warn that the
    var b = 16777217.0f64               // literal comparison is constant
    if (a as f64) != b { r += 1 }
    if (a as f64) == 16777216.0 { r += 2 }
    var t = 0.1f32
    var d = 0.1
    if (t as f64) != d { r += 4 }
    if t == (d as f32) { r += 8 }
    var bh: bf16 = 1.00390625
    if (bh as f32) == 1.0f32 { r += 16 }
    if 1e-10f32 > 0.0f32 { r += 32 }
    println(f"{16777217.0f32} {16777217.0f64} {0.1f32 as f64}")
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: __bf16 bh = static_cast<__bf16>(1.00390625f);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out; test $? -eq 63
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT: 16777216 16777217 0.10000000149011612
