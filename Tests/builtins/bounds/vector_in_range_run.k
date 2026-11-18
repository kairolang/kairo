// Every in-range Vector access at its edges: 0, len - 1, empty ranges at 0 and at len.
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
    var v: [i32] = [1, 2, 3]
    ck(v[at(0)] == 1 && v[at(2)] == 3, "index ends")
    v[at(2)] = 9
    ck(v[2] == 9, "write")
    ck(v[0..0].size() == 0 && v[at(3)..at(3)].size() == 0, "empty ranges")
    ck(v[at(3)..].size() == 0 && v[..at(0)].size() == 0, "empty from and to")
    ck(v[0..=at(2)].size() == 3 && v[..=at(2)].size() == 3, "inclusive")
    v.insert(at(3), 4)
    v.insert(at(0), 0)
    ck(v.size() == 5 && v[0] == 0 && v[4] == 4, "insert at len and at 0")
    ck(v.remove(at(4)) == 4 && v.remove(at(0)) == 0, "remove ends")
    ck(v.swap_remove(at(2)) == 9 && v.size() == 2, "swap_remove last")
    {
        var d0 = v.drain(at(0)..at(0))
        ck(d0.remaining() == 0, "drain empty at 0")
    }

    {
        var d1 = v.drain(at(2)..at(2))
        ck(d1.remaining() == 0, "drain empty at len")
    }

    ck(v.size() == 2, "empty drains keep every element")
    {
        var d2 = v.drain(at(0)..at(2))
        ck(d2.remaining() == 2, "drain all")
    }

    ck(v.size() == 0, "full drain empties the vector")
    var e: [i32] = []
    ck(e[0..0].size() == 0 && e[..].size() == 0, "empty vector ranges")
    e.insert(at(0), 1)
    ck(e.size() == 1, "insert into empty")
    if failures != 0 {
        return 1
    }

    io::println("ok")
    return 0
}
