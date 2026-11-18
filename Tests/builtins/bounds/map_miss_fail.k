// An out-of-range access traps with a message naming the index or range and the length.
// REQUIRES: newlib
// RUN: rm -f %t.exe
// RUN: %kairo_new %s -O2 -o %t.exe --cache-dir %t.d
// RUN: not --crash %t.exe 2>&1 | %FileCheck %s
// CHECK: key is not in the map

import std::io

@no_inline
fn at(x: usize) -> usize {
    return x
}

fn main() -> i32 {
    var m: {i32: i32} = {1: 10}
    io::println(f"{m[at(2) as i32]}")
    return 0
}
