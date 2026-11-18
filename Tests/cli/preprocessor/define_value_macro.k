// `-D NAME=VALUE` defines the Kairo macro `NAME!`, whose expansion is the
// value's tokens: an integer or an expression reaches an `eval` constant,
// a string is a string literal, an identifier names whatever it names
// where it is used. `-D NAME` alone is 1. `defined!(NAME)` is true for a
// `-D` name, and a name nobody defined takes the `else`, where its `NAME!`
// is never looked up.
//
// `-D` is Kairo's: a C++ header does not see it. `--cxx-define` is the
// flag a header sees.

import std::io::println

ffi "c++" import "define_value_macro.hh"

eval if defined!(HEAP) {
    priv eval N: usize = HEAP!
} else {
    priv eval N: usize = 64
}

eval if defined!(FLAG) {
    priv eval F: i32 = FLAG!
} else {
    priv eval F: i32 = -1
}

eval if defined!(GREETING) {
    priv fn greeting() -> string { return GREETING! }
} else {
    priv fn greeting() -> string { return "none" }
}

priv fn pick() -> i32 {
    var small = 10
    var large = 20
    eval if defined!(WHICH) {
        return WHICH!
    } else {
        return 0
    }
}

fn main() -> i32 {
    println(f"{N} {sizeof [u8; N]} {F} {greeting()} {pick()} {header_saw_mode()}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only -D HEAP=4096 -D FLAG '-DGREETING="hi there"' -D WHICH=large 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.none.exe --cache-dir %t.d/none
// RUN: %t.none.exe | %FileCheck %s --check-prefix=NONE
// NONE: 64 64 -1 none 0 0

// RUN: %kairo %s -D HEAP=4096 -D FLAG '-DGREETING="hi there"' -D WHICH=large -D MODE -o %t.all.exe --cache-dir %t.d/all
// RUN: %t.all.exe | %FileCheck %s --check-prefix=ALL
// ALL: 4096 4096 1 hi there 20 0

// An expression value, and the long spelling.
// RUN: %kairo %s '-DHEAP=(1 << 4) + 1' --define=FLAG=7 --define WHICH=small -o %t.expr.exe --cache-dir %t.d/expr
// RUN: %t.expr.exe | %FileCheck %s --check-prefix=EXPR
// EXPR: 17 17 7 none 10 0

// RUN: %kairo %s --cxx-define MODE -o %t.cxx.exe --cache-dir %t.d/cxx
// RUN: %t.cxx.exe | %FileCheck %s --check-prefix=CXX
// CXX: 64 64 -1 none 0 1
