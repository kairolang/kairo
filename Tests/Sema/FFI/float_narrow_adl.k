// `tag(b, d)` with a Kairo `tag(b, x: bool)` in scope and C++'s `adl::tag`
// templates found through `b`: resolution correctly refused f64 -> bool and
// chose the floating-point template, but the name stayed bound to the
// Kairo function (it was the only one ordinary lookup saw), so the C++
// called it with `static_cast<bool>(d)` and returned 50. The winner from
// argument-dependent lookup is now what the call is bound to.

ffi "c++" import "float_narrow.h"

fn tag(b: adl::Box, x: bool) -> i32 { return 50 }

fn main() -> i32 {
    var b: adl::Box
    var d: f64 = 1.5
    var i: i32 = 1
    var t = true
    var r = tag(b, d)                 // 2:  adl::tag, floating
    r += tag(b, i) * 10               // 10: adl::tag, integral (exact; Kairo's needs no conversion from i32 either way)
    r += tag(b, t) * 100              // 5000: the Kairo function, exact
    return r - 5000                   // 12
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 12
