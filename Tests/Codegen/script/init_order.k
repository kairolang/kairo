// A root file with top-level statements and no `fn main` is a script. Its
// statements run in order inside a synthesized `main`, and a top-level
// binding whose initializer is not a constant is DEFERRED: it stays a
// global, but its initializer runs at its own line, between the statements
// around it. A constant initializer stays a static one (K). A function
// reads a deferred global through the runtime guard and, called after the
// line ran, sees the value; main itself reads it unguarded after its line.

import std::io::println

fn trace(s: i32) -> i32 { println(f"init {s}"); return s }
fn twice() -> i32 { return b * 2 }

const K: i32 = 7
println(f"start {K}")
var a = trace(1)
println(f"between {a}")
var b = trace(a + 1)
println(f"twice {twice()}")
b = 10
println(f"sum {a + b + K} {twice()}")

// --- lit wiring -----------------------------------------------------------
// The deferred globals are `T?` storage starting null, assigned in main at
// their line; the constant one keeps its static initializer.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      signed int const K = 7;
// CXX:      ::builtin::Nullable<signed int> a =
// CXX:      ::builtin::Nullable<signed int> b =
// CXX:      int main() {
// CXX:      init_order::a = static_cast<{{ ?}}::builtin::Nullable<signed int>>({{ ?}}::init_order::trace(1)));
// CXX:      init_order::b = static_cast<{{ ?}}::builtin::Nullable<signed int>>({{ ?}}::init_order::trace(({{ ?}}::init_order::a.__value() + 1))));
// CXX:      return 0;
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      start 7
// OUT-NEXT: init 1
// OUT-NEXT: between 1
// OUT-NEXT: init 2
// OUT-NEXT: twice 4
// OUT-NEXT: sum 18 20
