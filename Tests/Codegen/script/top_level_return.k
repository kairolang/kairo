// A top-level `return` returns from the synthesized main: its value is the
// exit status, and a bare one is `return 0`, as is the end of the file. A
// `return` inside a function or a closure is that function's own.

import std::io::println

fn pick(n: i32) -> i32 { return n * 2 }
var twice = fn (x: i32) -> i32 { return x + x }

var code = pick(1) + twice(1)
println(f"code {code}")
if code == 4 { return code - 1 }
println("not reached")
return

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      int main() {
// CXX:      return({{ ?}}::top_level_return::code.__value() - 1);
// CXX:      return 0;
// CXX-NEXT: return 0;
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out; test $? -eq 3
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      code 4
// OUT-NOT:  not reached
