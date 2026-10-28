// One instance with a value argument, named from two modules: lib.k spells
// `array<i32, WIDTH>` through its eval constant and returns `array<i32,
// 3>`; this file spells `array<i32, 3>`. All three are one registry
// instance (a value argument's identity is its integer), so the call
// type-checks, and both object files name the same C++ type.

ffi "c++" import "array"
import lib::*

fn main() -> i32 {
    var a = make(4)                      // [4, 4, 4]
    var b: cxx::std::array<i32, 3>
    b.fill(1)
    b[2] = 5
    return total(a) + total(b)           // 12 + 7 = 19
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 19
