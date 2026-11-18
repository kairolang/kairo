// Fixed arrays indexed at run time inside their extent: reads, writes,
// compound assignment, signed and narrow indexes, nested arrays, a field,
// a generic extent and loops all run unchanged with the bounds check.
// RUN: rm -f %t.exe
// RUN: %kairo %s -O0 -o %t.exe
// RUN: %t.exe | %FileCheck %s
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe
// RUN: %t.exe | %FileCheck %s
// CHECK: ok 45

import std::io

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

@no_inline
fn ati(x: i32) -> i32 {
    return x
}

struct Grid {
    var cells: [[i32; 3]; 2]
}

fn <T, eval N: usize> last(const a: [T; N], i: usize) -> T {
    return a[i]
}

fn main() -> i32 {
    var a: [i32; 3] = [1, 2, 3]
    ck(a[at(0)] == 1 && a[at(2)] == 3, "edges")
    a[at(2)] = 9
    a[at(1)] += 4
    ck(a[2] == 9 && a[1] == 6, "write")
    ck(a[ati(0)] == 1 && a[ati(2)] == 9, "signed index")
    var k: u8 = 2
    ck(a[k] == 9, "narrow index")
    var g: Grid = Grid{cells: [[1, 2, 3], [4, 5, 6]]}
    g.cells[at(1)][at(2)] = 60
    ck(g.cells[1][2] == 60 && g.cells[at(0)][at(1)] == 2, "nested")
    ck(last(a, at(2)) == 9, "generic extent")
    var s = 0
    for i in 0..3 {
        s += a[i]
    }

    for x in a {
        s += x
    }

    var n: usize = 0
    while n < 3 {
        s += a[n]
        n += 1
    }

    ck(s == 48, "loops")
    if failures != 0 {
        return 1
    }

    io::println(f"ok {s - 3}")
    return 0
}
