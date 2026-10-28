// SFINAE through a module boundary and through a generic: lib.k calls
// sfinae.h's pairs from a plain function and from `fn <T> pick`, whose
// call has no concrete argument until main instantiates it at i32 and at
// f64 -- each instance has to bind the OTHER template of the pair.

import lib::*

fn main() -> i32 {
    var a = pick_int(3)              // 1
    var b = pick(3)                  // 1 + 10
    var c = pick(2.5)                // 2 + 20
    return a + b + c                 // 34
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 34
