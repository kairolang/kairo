// Capture by const pointer (closures.md, Const Pointer Capture): `|const
// *x|` is a `*const T` to the original, so the closure reads the
// variable's CURRENT value, never a copy, and cannot write it. `|const *|`
// takes every capture that way. In C++ the capture is the address
// converted to `const T*`.

import std::io::println

fn main() -> i32 {
    var x = 10
    var y = 20
    var z = 30
    var closure = fn (a: i32)|const *x, const *y, const *z| -> i32 {
        return a + *x + *y + *z
    }
    println(f"named: {closure(1)}")
    x = 100
    println(f"current: {closure(1)}")

    var w = 5
    var all = fn ()|const *| -> i32 { return *w * 2 }
    w = 6
    println(f"all: {all()}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      named: 61
// OUT-NEXT: current: 151
// OUT-NEXT: all: 12

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: own(new auto([x = static_cast<const signed int *>(& x), y = static_cast<const signed int *>(& y), z = static_cast<const signed int *>(& z)](signed int a) mutable noexcept->signed int {
// CXX: own(new auto([w = static_cast<const signed int *>(& w)]() mutable noexcept->signed int {
