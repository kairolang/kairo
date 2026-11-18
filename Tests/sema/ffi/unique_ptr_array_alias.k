// `make_unique<kairo::Arr>(n)` over an incomplete-array alias (`Tok[]`) is a
// `unique_ptr<Tok[]>` and moves into a `unique_ptr<Tok[]>` parameter.

ffi "c++" import "unique_ptr_array_alias.h"

fn f(pp: unsafe *PP, t: Tok) {
    var n: usize = 3
    var arr = cxx::std::make_unique<kairo::Arr>(n);
    for var i: usize = 0; i < n; ++i { arr[i] = t; }
    pp->Enter(cxx::std::move(arr), n as u32, true, true);
}
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; echo DONE; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: DONE
