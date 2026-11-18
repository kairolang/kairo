// A call to an imported function template returning a reference to its
// deduced parameter has the substituted reference type, so a wrong use of the
// result is a Kairo type error at the call rather than an untyped value
// reaching codegen.

ffi "c++" import "template_ref_return.h"

fn main() -> i32 {
    var n: i32 = 3
    var s: string = pick_max(n, 4)
    var t: string = same(n)
    var u: string = moved(n)
    var w = pick_max(n, "x")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="I011W" --implicit-check-not="I003E"
// CHECK: template_ref_return_reject.k:10:21: error [SC028E]: cannot convert 'const i32&' to 'string'
// CHECK: template_ref_return_reject.k:11:21: error [SC028E]: cannot convert 'i32&' to 'string'
// CHECK: template_ref_return_reject.k:12:21: error [SC028E]: cannot convert 'i32&&' to 'string'
// CHECK: template_ref_return_reject.k:13:13: error [SC063E]: no matching overload for call to 'pick_max'
// CHECK: template_ref_return.h:4:1: note [I900N]: candidate not viable: cannot convert argument of type 'string' to parameter 'b' of type 'const T&'
