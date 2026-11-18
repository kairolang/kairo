// The compiler's hooks into the library, each exercised once on the
// two-word tree: a range loop, a slice loop, the vector-to-slice view, a
// nullable result, `match` on a string, the derived comparisons from
// `impl Ord`, and the two-word layouts.

import std::io

fn kind(const s: string) -> i32 {
    match s {
        case "one" { return 1 }
        case "two" { return 2 }
        default { return 0 }
    }
}

fn first_big(const xs: [const i32;]) -> i32? {
    for x in xs {
        if x > 2 { return x }
    }

    return null
}

fn main() -> i32 {
    var xs: [i32] = [1, 2, 3, 4]
    var total = 0
    for i in 0..4 { total += xs[i as usize] }
    io::println(f"range {total}")

    var sl: [const i32;] = xs
    var seen = 0
    for x in sl { seen += x }
    io::println(f"slice {seen}")

    var f? = first_big(sl)
    if f? { io::println(f"first {f}") }

    io::println(f"match {kind("two")} {kind("six")}")

    var a = "abc"
    var b = "abd"
    if a < b { io::println("less") }
    if (a <=> b) == Ordering::Less { io::println("ordering") }
    if a != b { io::println("differ") }

    var w = sizeof(usize)
    if sizeof(string) == 2 * w && sizeof([i32]) == 2 * w && sizeof([i32;]) == 2 * w {
        io::println("two words")
    }

    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK:      range 10
// CHECK-NEXT: slice 10
// CHECK-NEXT: first 3
// CHECK-NEXT: match 2 0
// CHECK-NEXT: less
// CHECK-NEXT: ordering
// CHECK-NEXT: differ
// CHECK-NEXT: two words
