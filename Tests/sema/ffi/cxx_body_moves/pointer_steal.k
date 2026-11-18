// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
//
// The same through a C++ `T*`: `*p` bound to a move constructor's `T&&`
// moves the Kairo object the pointer was taken from.

ffi "c++" import "inputs/moves.h"

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

fn moved() -> i32 {
    var h = Res(7)
    steal_ptr(unsafe &h)
    return h.id
}

fn borrowed() -> i32 {
    var h = Res(7)
    look_ptr(unsafe &h)
    return h.id
}

fn main() -> i32 {
    return moved() + borrowed()
}

// --- lit wiring ---
// CHECK: pointer_steal.k:23:12: error [SC052E]: 'h' is used after being moved
// CHECK: pointer_steal.k:22:5: note {{.*}}: 'h' was moved here, by the call to 'steal_ptr'
// CHECK: moves.h:12:50: note {{.*}}: 'steal_ptr' moves it here
// CHECK-NOT: error
