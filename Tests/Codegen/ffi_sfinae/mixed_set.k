// One overload set drawing from Kairo and C++: `b + x` gathers the Kairo
// `op +` declared here and sfinae.h's two `adl::operator+` templates,
// found through the operand's namespace. Clang judges only the imported
// candidates; the Kairo one ranks as it always did, and the usual
// tiebreaks run on the survivors -- an exact non-generic Kairo operator
// beats a template, and a Kairo one that would need a conversion loses to
// the one template whose condition holds.

ffi "c++" import "sfinae.h"

fn op + (b: adl::Box, x: i64) -> i32 { return 50 }

fn main() -> i32 {
    var b: adl::Box
    var a: i64 = 1
    var i: i32 = 1
    var d: f64 = 1.0
    var r = b + a                    // 50: Kairo, exact
    r += b + i                       // 1:  the integral template (i32 -> i64 would convert)
    r += b + d                       // 2:  the floating one
    return r                         // 53
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 53
