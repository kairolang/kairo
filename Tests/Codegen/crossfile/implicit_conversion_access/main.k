// A `pub` implicit conversion is usable from another file (as an argument,
// an initializer and an explicit `as`), and so is a function of the file
// that declares a `priv` one: the access check refuses only the uses outside
// that file.

import lib::*

fn take(x: i64) -> i64 { return x }

fn main() -> i32 {
    var p = Pubby(5)
    var a = take(p)
    var b: i64 = p
    var c = p as i64
    var d = inside(Secret(2))
    return (a + b + c + d) as i32 - 19
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.e
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.e
// RUN: %t.o2.exe
