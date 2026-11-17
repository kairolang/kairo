// The `[const T;]` that a `[T;]`'s read range operator returns has the
// whole read API, like any other `[const T;]`.
//
// Expected to fail until the extension members reach that value: Sema
// takes the extension's `T` as the element without its const, and clang
// rejects the `Slice<const int>` receiver for `Slice<int>`'s member. Then
// remove the XFAIL line, and len_of in api_run.k.

import std::io

fn main() -> i32 {
    var v: [i32]  = [1, 3, 4, 4, 7, 9]
    var s: [i32;] = v
    io::println(f"{s[1..4].size()} {s[2..].contains(9)} {s[..2].starts_with(s[..1])}")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// XFAIL: *
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK: 3 true true
