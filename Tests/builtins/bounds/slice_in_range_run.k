// Every in-range slice access at its edges: 0, len - 1, empty ranges at 0 and at len.
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d
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
    var v: [i32]  = [1, 2, 3]
    var s: [i32;] = v
    ck(s[at(0)] == 1, "first")
    ck(s[at(2)] == 3, "last")
    s[at(0)] = 7
    s[at(2)] = 9
    ck(v[0] == 7 && v[2] == 9, "writes reach the vector")
    ck(s[0..0].size() == 0, "empty range at 0")
    ck(s[at(3)..at(3)].size() == 0, "empty range at len")
    ck(s[at(3)..].size() == 0, "from len")
    ck(s[..at(0)].size() == 0, "to 0")
    ck(s[0..at(3)].size() == 3, "full range")
    ck(s[0..=at(2)].size() == 3, "inclusive full")
    ck(s[..=at(2)].size() == 3, "to inclusive")
    ck(s[at(1)..].size() == 2, "from 1")
    s[at(1)..at(3)][0] = 5
    ck(v[1] == 5, "range write")
    var (a, b) = s.split_at(at(0))
    ck(a.size() == 0 && b.size() == 3, "split at 0")
    var (c, d) = s.split_at(at(3))
    ck(c.size() == 3 && d.size() == 0, "split at len")
    var n: i32 = 0
    for w in s.windows(3) { n += 1 }
    for w in s.windows(4) { n += 100 }
    for w in s.chunks(2) { n += 10 }
    ck(n == 21, "windows and chunks")
    s.swap(0, at(2))
    ck(v[0] == 9 && v[2] == 7, "swap ends")
    s.swap(at(1), at(1))
    ck(s.get(at(3)) == &null && s.get(at(2)) != &null, "get")
    ck(s.first() != &null && s.last() != &null, "first and last")
    ck(s.at(-1) != &null && s.at(-3) != &null && s.at(-4) == &null, "at")
    var e: [i32;] = v[0..0]
    ck(e.first() == &null && e.last() == &null && e.get(0) == &null, "empty first, last, get")
    ck(e[0..0].size() == 0 && e[..].size() == 0, "empty slice ranges")
    if failures != 0 {
        return 1
    }

    io::println("ok")
    return 0
}
