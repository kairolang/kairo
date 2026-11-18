// A defaulted template parameter that no argument deduces takes its default,
// and the call has that type, not an unknown one: a member the default type
// lacks is R025E, and the result of `same` (an `i32` here) does not convert
// to a string.

ffi "c++" import "template_default_return.h"

fn main() -> i32 {
    var x: i32 = 4
    var a = wrap(x)
    var n = a.nothing()
    var s: string = same(x)
    return a.get()
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I011W' --implicit-check-not='I003E'
// CHECK: template_default_return_reject.k:11:15: error [R025E]: no member named 'nothing' in 'Box'
// CHECK: template_default_return_reject.k:12:21: error [SC028E]: cannot convert 'i32' to 'string'
