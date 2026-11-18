// Overload ordering of `*B?` beside `*const B?` does not make a const pointer
// convert to the non-const parameter: with only the non-const overload, a
// `*const B?` argument has no matching overload.

class B { var x: i32 = 1 }

fn g(p: *B?) -> i32 { return 1 }

fn main() -> i32 {
    var b = B()
    var cb: *const B? = const &b
    return g(cb)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: nullable_overload_cv_reject.k:12:12: error [SC063E]: no matching overload for call to 'g'
// CHECK: nullable_overload_cv_reject.k:7:1: note [I900N]: candidate not viable: cannot convert argument of type '*const B?' to parameter 'p' of type '*B?'
