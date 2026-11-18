// A closure with captures is callable on Windows; a by-copy capture keeps
// its own state between calls.

import std::io::println

fn apply(f: fn (i32) -> i32, x: i32) -> i32 {
    return f(x)
}

fn main() -> i32 {
    var base = 10
    var add = fn (y: i32) -> i32 { return y + base }
    println(f"made {add(5)}")
    var acc = 0
    var keep = fn () -> i32 { acc += 1; return acc }
    keep()
    keep()
    println(f"counter {keep()} original {acc}")
    println(f"sum {apply(fn (v: i32) -> i32 { return v * 2 }, 6)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: wine, sysroot-x86_64-windows-gnu
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s --target=x86_64-windows-gnu -o %t.exe --cache-dir %t.d
// RUN: %wine %t.exe | %FileCheck %s --match-full-lines
// CHECK: made 15
// CHECK-NEXT: counter 3 original 0
// CHECK-NEXT: sum 12
