// A write through a pointer binder over a read-only C++ range whose
// iterator is a raw `const T*` is a Kairo error at the write, as it is for
// an iterator that yields `const T&`.

ffi "c++" import "cxx_const_pointer_iter.h"

struct Spec {
    var a: usize = 0
}

struct Ctx {
    var ptrs: cp::PtrVec<Spec>
}

fn bump(const c: Ctx) {
    for *s in c.ptrs {
        s->a = 1
    }
}

fn main() -> i32 {
    var c = Ctx{}
    bump(c)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: cxx_const_pointer_iter_err.k:17:9: error [SC071E]: cannot assign to a field of '*s': 's' points to const
// CHECK: cxx_const_pointer_iter_err.k:16:10: note [I900N]: 's' declared as a pointer to const here
// CHECK-NOT: CL001E
