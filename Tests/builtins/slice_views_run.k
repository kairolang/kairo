// A two-word vector is viewed as a slice through its own `op as`: the
// vector is the conversion's receiver, so it is not moved and stays usable,
// whether the view is mutable, const, or made at a call. A mutable slice
// views as a const one.

import std::io

fn sum(const xs: [const i32;]) -> i32 {
    var t = 0
    for x in xs { t += x }
    return t
}

fn main() -> i32 {
    var xs: [i32] = [1, 2, 3]
    var m: [i32;] = xs
    var c: [const i32;] = m
    io::println(f"{sum(m)} {sum(c)} {sum(xs)}")
    xs.push(4)
    io::println(f"{sum(xs)} {xs.size()}")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK:      6 6 6
// CHECK-NEXT: 10 4
