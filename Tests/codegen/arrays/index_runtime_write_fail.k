// A fixed array written at a run-time index past its extent crashes before
// the store; the index expression runs once.
// RUN: rm -f %t.exe
// RUN: %kairo %s -O0 -o %t.exe
// RUN: not --crash %t.exe 2>&1 | %FileCheck %s
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe
// RUN: not --crash %t.exe 2>&1 | %FileCheck %s
// CHECK: bump 1
// CHECK-NEXT: bump 2
// CHECK-NEXT: index 13 is out of bounds for length 4
// CHECK-NOT: after

import std::io

var calls: usize = 0

@no_inline
fn bump() -> usize {
    calls += 1
    io::println(f"bump {calls}")
    return calls * 13 - 13
}

struct Holder {
    var v: [i32; 4]
}

fn main() -> i32 {
    var h: Holder = Holder{v: [0, 0, 0, 0]}
    h.v[bump()] = 7
    h.v[bump()] = 8
    io::println(f"after {h.v[0]}")
    return 0
}
