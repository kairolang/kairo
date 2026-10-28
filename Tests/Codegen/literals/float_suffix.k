// The float suffixes every target has (primitives.mdx, Floating-Point):
// f16, f32, f64. Each reached clang as written -- "invalid suffix 'f32' on
// floating constant" -- and is now spelled with the C++ suffix of its type
// (`f16`, `f`, none), so clang parses the digits at that format. Exponents,
// hex floats, a float suffix on an integer body, `_` separators and
// negation ride along. f80 and f128 exist on some targets only:
// float_suffix_wide.k.

import std::io::println

fn pick(x: f32) -> i32 { return 32 }
fn pick(x: f64) -> i32 { return 64 }
fn pick(x: f16) -> i32 { return 16 }

fn <T> echo(x: T) -> T { return x }

fn main() -> i32 {
    println(f"{1.5f16} {1.5f32} {1.5f64}")
    println(f"{pick(1.5f16)} {pick(1.5f32)} {pick(1.5f64)} {pick(echo(2.0f32))}")
    println(f"{-2.25f32} {2.5e3f32} {1e-3f64} {0x1.8p3f32} {5f32} {1_000.5f32}")

    var r = 0
    var e = 1.5f64
    if e == 1.5 { r += 1 }
    if (e * 2.0f64) == 3.0 { r += 2 }
    var x = 0.5f32
    if (x + x) == 1.0f32 { r += 4 }
    var h = 0.25f16
    if (h + h) == 0.5f16 { r += 8 }
    var q = -0.5f32
    if (q * q) == 0.25f32 { r += 16 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: float x = 0.5f;
// CXX: _Float16 h = 0.25f16;
// CXX: float q =(- 0.5f);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out; test $? -eq 31
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      1.5 1.5 1.5
// OUT-NEXT: 16 32 64 32
// OUT-NEXT: -2.25 2500 0.001 12 5 1000.5
