// A DIRECTORY named main holds module `main::x`; its top C++
// namespace segment is `main` too, so it is renamed `main_` (only the top
// segment: `main_::x`). The import still says `main::x`.

import main::x

fn main() -> i32 { return x::get() }

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: cd %S && { %kairo use.k -o %t.exe --cache-dir %t.d --print-ir 2>&1 || true; } | %FileCheck %s
// RUN: %t.exe; test $? -eq 42
// CHECK: namespace main_::x {
