// f80 and f128 literals (primitives.mdx: f80 is x87 `long double`, f128 is
// `__float128`), suffixed and contextually typed. The C++ suffixes are `L`
// and `Q`, and the point of spelling them is precision: an unsuffixed
// `0.1` in an f80 or f128 context was the DOUBLE 0.1 widened, so its digits
// past the 53rd bit were the double's error, not the decimal's. Re-read at
// the wide format, 0.1 as f128 is not 0.1 as f64 widened.
//
// f80 has no f-string row (fstring_f80.k): it is compared, not printed.

import std::io::println

fn main() -> i32 {
    var r = 0
    var e = 1.5f80
    if (e * 2.0f80) == 3.0f80 { r += 1 }
    var e1: f80 = 0.1
    if e1 != (0.1f64 as f80) { r += 2 }             // L: the decimal at 64 bits of mantissa
    if 0.1f80 == e1 { r += 4 }
    var q1: f128 = 0.1
    if q1 != (0.1f64 as f128) { r += 8 }            // Q: and at 113
    if 0.1f128 == q1 { r += 16 }
    var q = -0.5f128
    if (q * q) == 0.25f128 { r += 32 }
    println(f"{1.5f128} {q1}")
    return r
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: host-x86_64, host-linux
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: long double e = 1.5L;
// CXX: long double e1 = 0.1L;
// CXX: __float128 q1 = 0.1Q;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out; test $? -eq 63
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT: 1.5 0.1
