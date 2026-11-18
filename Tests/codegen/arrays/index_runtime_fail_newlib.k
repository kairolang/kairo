// The fixed-array bounds check is the compiler's, not a library's: built
// against the new library it crashes with the same message.
// REQUIRES: newlib
// RUN: rm -f %t.exe
// RUN: %kairo_new %s -O2 -o %t.exe --cache-dir %t.d
// RUN: not --crash %t.exe 2>&1 | %FileCheck %s
// CHECK: index 5 is out of bounds for length 2

import std::io

@no_inline
fn at(x: usize) -> usize {
    return x
}

fn main() -> i32 {
    var a: [u8; 2] = [1, 2]
    a[at(1)] = 3
    io::println(f"{a[at(1)]}")
    a[at(5)] = 4
    return 0
}
