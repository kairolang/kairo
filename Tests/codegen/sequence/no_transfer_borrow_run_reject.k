// The negative of no_transfer_borrow_run.k: a by-value parameter of a type
// with no copy and no move still cannot take an lvalue. Ordering binds the
// argument as a borrow, but the parameter itself would need a copy, and
// that is reported before lowering runs.

ffi "c++" import "no_transfer_borrow.h"

fn take(b: Pinned<i32, 4>, extra: i32) -> i32 {
    return (b.size() as i32) + extra
}

fn add(p: unsafe *Pinned<i32, 4>, v: i32) -> i32 {
    p->push_back(v)
    return v
}

fn main() -> i32 {
    var b: Pinned<i32, 4>
    return take(*(unsafe &b), add(unsafe &b, 1))
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: no_transfer_borrow_run_reject.k:19:17: error [SC182E]: cannot copy a value of type 'Pinned<i32, 4>': its copy constructor is deleted
// CHECK-NOT: CL001E
