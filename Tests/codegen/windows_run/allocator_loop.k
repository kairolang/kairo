// Heap allocation and release in a loop go through the Windows allocator
// without corrupting data.

import std::io::println

fn main() -> i32 {
    var n = 0
    var sum: i64 = 0
    var round = 0
    while round < 100 {
        var v: [i64]
        var i: i64 = 0
        while i < 1000 { v.push(i + round); i += 1 }
        for *x in v { sum += *x }
        n += v.size() as i32
        round += 1
    }
    println(f"allocated {n} checksum {sum}")

    var total = 0
    for k in 0..20000 {
        var s = f"item {k}"
        total += 1
    }
    println(f"strings {total}")
    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: wine, sysroot-x86_64-windows-gnu
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s --target=x86_64-windows-gnu -o %t.exe --cache-dir %t.d
// RUN: %wine %t.exe | %FileCheck %s --match-full-lines
// CHECK: allocated 100000 checksum 54900000
// CHECK-NEXT: strings 20000
// CHECK-NEXT: ok
