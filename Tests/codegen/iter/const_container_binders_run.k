// A const map, set or vector iterates: `for x in c` and `for (k, v) in m`
// bind values, and `for const *x` / `for (k, const *p)` bind pointers to
// const. A binder that writes (`*p`) stays for a mutable container.

fn sum(const m: {i32: i32}, const s: {i32}, const v: [i32]) -> i32 {
    var t = 0
    for (k, v2) in m { t = t + k + v2 }
    for (k, const *p) in m { t = t + k + *p }
    for x in s { t = t + x }
    for const *x in s { t = t + *x }
    for x in v { t = t + x }
    for const *x in v { t = t + *x }
    return t
}

fn main() -> i32 {
    var m: {i32: i32} = {1: 2, 3: 4}
    var s: {i32} = {5, 6}
    var v: [i32] = [7, 8]
    for (k, *p) in m { *p = *p + 1 }
    for *x in v { *x = *x + 1 }
    // m: 1:3 3:5 -> 12 twice = 24; s: 11 twice = 22; v: 8, 9 -> 17 twice = 34
    return sum(m, s, v) - 80
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.e
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.e
// RUN: %t.o2.exe
