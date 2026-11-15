// RUN: { %kairo %s --type-check-only --print-unchecked-assumptions -fno-strict-cxx-moves 2>&1 || true; } | %FileCheck %s
//
// A virtual call or a call through a function pointer runs code the walk
// cannot read, but the parameter types are those of every override and of
// every function the pointer can hold: an argument bound to a reference or
// pointer to const cannot be moved by any of them, one bound to `T&&` is
// moved by all of them, and only a `T&` / `T*` to non-const is not known.

ffi "c++" import "Inputs/walk.h"

class Res {
    pub var id: i32 = 0
    fn Res(self, id: i32) {
        self.id = id
    }

    @move fn Res(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
}

fn virtual_const(v: unsafe *Viewer<Res>) -> i32 {
    var h = Res(1)
    view_const(v, &h)
    return h.id
}

fn virtual_mut(v: unsafe *Viewer<Res>) -> i32 {
    var h = Res(2)
    view_mut(v, &h)
    return h.id
}

fn pointer_const() -> i32 {
    var h = Res(3)
    via_const_ptr(&h)
    return h.id
}

fn pointer_rvalue() -> i32 {
    var h = Res(4)
    via_rvalue_ptr(&h)
    return h.id
}

fn pointer_mut() -> i32 {
    var h = Res(5)
    via_mut_ptr(&h)
    return h.id
}

fn main() -> i32 {
    return 0
}

// --- lit wiring ---
// CHECK-NOT: virtual_and_pointer_calls.k:25:{{.*}}unchecked assumption
// CHECK: virtual_and_pointer_calls.k:31:5: unchecked assumption: 'view_mut' is assumed not to move out of 'h': it passes it to 'Viewer<{{.*}}Res>::poke', a virtual call
// CHECK-NOT: virtual_and_pointer_calls.k:37:{{.*}}unchecked assumption
// CHECK: virtual_and_pointer_calls.k:49:5: unchecked assumption: 'via_mut_ptr' is assumed not to move out of 'h': 'via_mut_ptr' passes it to a call through a pointer
// CHECK: virtual_and_pointer_calls.k:44:12: error [SC052E]: 'h' is used after being moved
// CHECK: virtual_and_pointer_calls.k:43:5: note {{.*}}: 'h' was moved here, by the call to 'via_rvalue_ptr'
// CHECK-NOT: unchecked assumption
