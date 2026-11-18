// Reading a present key of a HashMap, and the nullable lookups on a missing one.
// REQUIRES: newlib
// RUN: rm -f %t.exe
// RUN: %kairo_new %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok

import std::io
import std::iter::*

var failures: i32 = 0

fn ck(cond: bool, const what: string) {
    if !cond {
        failures += 1
        io::println(f"FAIL {what}")
    }
}

@no_inline
fn at(x: usize) -> usize {
    return x
}

fn main() -> i32 {
    var m: {i32: i32} = {1: 10, 2: 20}
    ck(m[1] == 10 && m[2] == 20, "hit")
    ck(m.get_entry(3) == &null, "miss is null")
    ck(m.get_or(3, 7) == 7, "get_or")
    var e: {i32: i32} = {}
    ck(e.first() == &null && e.last() == &null, "empty map")
    var w: [i32] = [1, 2, 3]
    var it? = iter(w.iter()).copied().nth(5)
    ck(!it?, "nth past the end is null")
    if failures != 0 {
        return 1
    }

    io::println("ok")
    return 0
}
