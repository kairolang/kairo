// A literal made of adjacent segments is read whole every time it is
// lowered. One literal reaches lowering more than once when a macro body
// that writes it is expanded twice (`greet!`), and when a macro names its
// argument twice (`twice!`): each use is the full text, not the first
// segment alone.
import std::io::println

macro greet!() { "ab" "cd" }
macro twice!(s) { println(s) println(s) }

fn main() -> i32 {
    println(greet!())
    println(greet!())
    twice!("12" "34")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK:      abcd
// CHECK-NEXT: abcd
// CHECK-NEXT: 1234
// CHECK-NEXT: 1234
