// An f-string on the two-word library: a string hole is read where it is
// (the string cannot be copied), an integer hole is formatted, and
// FmtBuf::finish hands back a string. Appending keeps the codepoint count.

import std::io

fn main() -> i32 {
    var name = "kairo"
    var n    = 42
    io::println(f"hello {name}, n = {n}!")
    io::println(f"{name}{name}")
    var s = "ab"
    s += "cd"
    s.push_str("é")
    io::println(s)
    if s == "abcdé" { io::println("equal") }
    io::println(f"{s.size()} {s.codepoints()}")
    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK:      hello kairo, n = 42!
// CHECK-NEXT: kairokairo
// CHECK-NEXT: abcdé
// CHECK-NEXT: equal
// CHECK-NEXT: 6 5
