// A C++ function type used as a template argument (`FRef<bool(int)>`) imports
// as the written `fn(i32) -> bool`, so the imported parameter of `take` and a
// `FRef<fn(i32) -> bool>` written in Kairo are one instance (SC063E).

ffi "c++" import "function_type_template_arg.h"

fn f() {
    var c = fn (a: i32) -> bool { return true; };
    take(FRef<fn (i32) -> bool>(c));
}
fn main() -> i32 { f(); return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; echo DONE; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: DONE
