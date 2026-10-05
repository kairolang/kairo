// `@implicit fn op as` is applied without an `as`, and an array is viewed
// as a slice the same way: as an argument, an initializer, and the base of
// a range subscript.

struct Meters {
    var v: i32
    @implicit fn op as (const self) -> i32 { return self.v }
}

fn twice(x: i32) -> i32 { return x * 2 }

fn sum(const xs: [i32;]) -> i32 {
    var s: i32 = 0
    for x in xs { s += x }
    return s
}

fn main() -> i32 {
    var m = Meters{ v: 4 }
    var n: i32 = m                   // initializer: 4
    var t = twice(m)                 // argument: 8

    var a: [i32; 4] = [1, 2, 3, 4]
    var whole = sum(a)               // the array as a slice: 10
    var part  = sum(a[1..3])         // a range of it: 2 + 3
    var v: [i32;] = a                // a view, not a copy
    v[0] = 10                        // writes a[0]
    return n + t + whole + part + a[0]   // 4 + 8 + 10 + 5 + 10 == 37
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 37
