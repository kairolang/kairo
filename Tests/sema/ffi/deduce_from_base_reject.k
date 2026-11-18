// Deduction of a class template argument from a derived argument needs the
// argument to be an instance of the template or derived from one: an
// unrelated value is still a call with no matching overload.

ffi "c++" import "deduce_from_base.h"

struct Unrelated { var v: i32 = 0 }

fn main() -> i32 {
    var d: Derived
    var u: Unrelated
    var a = get(&u)
    var b = get(5)
    var c: string = get(&d)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: deduce_from_base_reject.k:12:13: error [SC063E]: no matching overload for call to 'get'
// CHECK: deduce_from_base_reject.k:13:13: error [SC063E]: no matching overload for call to 'get'
// CHECK: deduce_from_base_reject.k:14:21: error [SC028E]: cannot convert 'i32' to 'string'
