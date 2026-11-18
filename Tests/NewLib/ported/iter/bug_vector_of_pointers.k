// A vector whose element is a pointer (`[*const T]`) compiles: the class's
// own members are instantiated, `Slice::sort_by` among them, and the iterator
// consumers whose result holds the items of a slice iterator
// (`iter(v.iter()).partition(..)` and `.group_by(..)`) return `[*const T]`.
// `partition` splits the pointers.

import std::iter::*
import self::Inputs::probe::*

fn is_big(x: *const *const i64) -> bool = **x > 1

fn main() -> i32 {
    var v: [i64] = [1, 2, 3]
    var p = iter(v.iter()).partition(is_big)
    expect(p.0.size() == 2 && p.1.size() == 1, "partition of pointers")
    return finish()
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
