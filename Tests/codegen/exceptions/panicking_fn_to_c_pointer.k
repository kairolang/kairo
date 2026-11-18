// A fn that can panic does not convert to a C function pointer: its lowered
// return carries the panic (a Panic<...> slot), not the `int` C++ expects,
// so `apply(may_fail, 1)` must be rejected at the call rather than handing
// C++ a pointer of the wrong signature. The non-panicking form is case 1 of
// callback_matrix.k.
ffi "c++" import "guard.hh"

struct Negative { var v: i32 }

fn may_fail(x: i32) panic(Negative) -> i32 {
    if x < 0 { panic Negative { v: x } }
    return x
}

fn main() -> i32 {
    return apply(may_fail, 1)
}

// --- lit wiring -----------------------------------------------------------
// RUN: not %kairo %s --type-check-only --diag-show-ids 2> %t.err
// RUN: %FileCheck %s < %t.err
// CHECK: panicking_fn_to_c_pointer.k:16:12: error [SC063E]: no matching overload for call to 'apply'
// CHECK: guard.hh:{{[0-9]+}}:1: note [I900N]: candidate not viable: cannot convert argument of type 'unsafe fn (i32) panic(Negative) -> i32' to parameter 'f' of type 'unsafe fn (i32) -> i32'
