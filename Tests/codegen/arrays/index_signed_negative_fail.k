// A negative signed index into a fixed array crashes and the message shows
// the index as written, not wrapped to an unsigned value.
// RUN: rm -f %t.exe
// RUN: %kairo %s -O0 -o %t.exe
// RUN: not --crash %t.exe 2>&1 | %FileCheck %s
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe
// RUN: not --crash %t.exe 2>&1 | %FileCheck %s
// CHECK: index -1 is out of bounds for length 3

import std::io

@no_inline
fn at(x: i32) -> i32 {
    return x
}

fn main() -> i32 {
    var a: [i32; 3] = [1, 2, 3]
    io::println(f"{a[at(-1)]}")
    return 0
}
