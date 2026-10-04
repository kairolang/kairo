fn count(r: Range<i32>) -> i32 {
    var n: i32 = 0
    for i in r { n += 1 }
    return n
}

fn trace(t: *i32, d: i32, v: i32) -> i32 {
    *t = *t * 10 + d
    return v
}

fn main() -> i32 {
    var a = 0..4
    var b = 2..=5
    var e = 5..5
    var t: i32 = 0
    var o = trace(&t, 1, 0)..trace(&t, 2, 3)
    var hits: i32 = 0
    var top = (250 as u8)..=255
    for x in top { hits += 1 }
    var s = count(a) + count(b) + count(e) + count(o)   // 4 + 4 + 0 + 3
    if t != 12 { return 0 }                            // begin before end
    return s + hits                                    // 11 + 6 == 17
}

// --- lit wiring -----------------------------------------------------------
// count takes a Range parameter, so the run-time `inclusive` path runs with
// both values; o checks begin is evaluated before end (t == 12); top checks
// that `..=255` on u8 runs 6 times and does not overflow.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: Range<signed int> {
// CXX: .begin =
// CXX: .inclusive = true

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 17
