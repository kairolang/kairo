fn main() -> i32 {
    var s: i32 = 0
    for i in 0..5 { s += i }
    for i in 1..=3 { s += i }
    for i in 5..5 { s += 100 }
    for i in 0..10 {
        if (i % 2) == 0 { continue }
        if i > 7 { break }
        s += i
    }
    var hits: i32 = 0
    for b in (250 as u8)..=255 { hits += 1 }
    return s + hits                     // 10 + 6 + 0 + 16 + 6 == 38
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// The u8 loop ending at 255 is the overflow check: it must run exactly 6
// times and stop.
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 38
