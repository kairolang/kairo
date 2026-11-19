// Every in-range string access at its edges: 0, len - 1, empty ranges at 0 and at len, char boundaries.
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
    var s = "héllo"
    ck(s[at(0)] == 'h' && s[at(1)] == 'é' && s[at(5)] == 'o', "index")
    ck(s[0..0].size() == 0 && s[at(6)..at(6)].size() == 0, "empty ranges")
    ck(s[at(6)..].size() == 0 && s[..at(0)].size() == 0, "empty from and to")
    ck(s[0..at(6)].size() == 6 && s[..=at(5)].size() == 6 && s[0..=at(5)].size() == 6, "full")
    ck(s[at(1)..at(3)].size() == 2, "one two-byte char")
    ck(s[at(3)..].size() == 3, "tail")
    ck(s.get(at(6)) == null && s.get(at(2)) == null, "get off the end and off a boundary")
    var e = ""
    ck(e[0..0].size() == 0 && e[..].size() == 0 && e.get(0) == null, "empty string")
    if failures != 0 {
        return 1
    }

    io::println("ok")
    return 0
}
