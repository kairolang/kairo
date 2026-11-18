// A fixed array read at a run-time index past its extent crashes with a
// message naming the index and the length, at every optimization level.
// RUN: rm -f %t.exe
// RUN: %kairo %s -O0 -o %t.exe
// RUN: not --crash %t.exe 2>&1 | %FileCheck %s
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe
// RUN: not --crash %t.exe 2>&1 | %FileCheck %s
// CHECK: index 3 is out of bounds for length 3
// CHECK-NOT: unreachable

import std::io

@no_inline
fn at(x: usize) -> usize {
    return x
}

fn get(const a: [i32; 3], i: usize) -> i32 {
    return a[i]
}

fn main() -> i32 {
    var a: [i32; 3] = [1, 2, 3]
    io::println(f"{get(a, at(3))}")
    io::println("unreachable")
    return 0
}
