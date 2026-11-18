// An out-of-range access traps with a message naming the index or range and the length.
// REQUIRES: newlib
// RUN: rm -f %t.exe
// RUN: %kairo_new %s -O2 -o %t.exe --cache-dir %t.d
// RUN: not --crash %t.exe 2>&1 | %FileCheck %s
// CHECK: range 0..9 is out of bounds for length 6

import std::io

@no_inline
fn at(x: usize) -> usize {
    return x
}

fn main() -> i32 {
    var s = "héllo"
    io::println(f"{s[..at(9)]}")
    return 0
}
