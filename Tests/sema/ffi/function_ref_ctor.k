// An explicit `fref<fn (i32, bool) -> i32>(c)` constructs a C++ class whose
// only constructor is a constrained template, behind a partial specialization
// over `Ret(Params...)` with a declared-only primary. A written `fn(...)` as a
// template argument is the C++ function type `R(A)`; spelled as `R(*)(A)` the
// partial never matched, the instance stayed unfilled and its constructors
// were invisible (SC038E "declares no constructor taking arguments").

ffi "c++" import "function_ref_ctor.h"

fn f() {
    var c = fn (a: i32, b: bool) -> i32 { return 0; };
    var r = fref<fn (i32, bool) -> i32>(c);
}
fn main() -> i32 { f(); return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; echo DONE; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: DONE
