// A `filter` does not know how many items it passes on, so a chain through
// one is not `ExactSize`: `remaining()` on it is an error where it is
// called, and the chain before the filter still has it.

import std::iter::*

fn is_even(x: *const i32) -> bool = (*x & 1) == 0

fn main() -> i32 {
    var v: [i32] = [1, 2, 3, 4]
    var sized = iter(v.iter()).copied().remaining()
    var unsized = iter(v.iter()).copied().filter(is_even).remaining()
    return (sized + unsized) as i32
}

// CHECK-NOT: filter_not_exact_size.k:11:
// CHECK: filter_not_exact_size.k:12:{{[0-9]+}}: error [SC162E]: 'Filter<Copied<SliceIter<i32>>>' does not conform to 'ExactSize'

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: { %kairo --type-check-only %s --cache-dir %t.d || true; } 2>&1 | %FileCheck %s
