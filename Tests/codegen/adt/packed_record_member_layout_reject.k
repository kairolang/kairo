// A `@packed` record whose members are primitives, arrays of primitives or
// other packed records keeps its fully packed layout, and a generic ADT over
// it predicts the same size clang computes (the emitted static_assert holds,
// so the program compiles). Only non-POD record members stay aligned.

import std::io

@packed struct PI { var a: i64; var b: u8 }
@packed struct Q1 { var a: u8; var b: i32 }
@packed struct Q2 { var a: u8; var s: [i32; 2] }
@packed struct Q3 { var a: u8; var s: PI }

enum <T> EP { A { p: T }, B }

fn main() -> i32 {
    var e1: EP<Q1> = EP<Q1>::B
    var e2: EP<Q2> = EP<Q2>::B
    var e3: EP<Q3> = EP<Q3>::B
    io::println(f"{sizeof PI}/{alignof PI} {sizeof Q1}/{alignof Q1} {sizeof Q2}/{alignof Q2} {sizeof Q3}/{alignof Q3}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d/o0 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='error ['
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d/o2
// RUN: %t.o2.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT: 9/1 5/1 9/1 10/1
