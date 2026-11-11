// A named `|*count|` capture of a script-mode global. ExprTyper
// types `count` in the body as the `*i32` pointer (closures.mdx, Capture by
// Pointer), but a global is named in place, not captured, so the body
// dereferenced the global's own `int` (CL001E "indirection requires pointer
// operand"). The name there is the global's address, so every write
// reaches the global.

import std::io

var count = 0
var increment = fn ()|*count| {
    *count += 1
}

increment()
increment()
io::println(f"{count}")

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --match-full-lines < %t.out
// CHECK: 2
