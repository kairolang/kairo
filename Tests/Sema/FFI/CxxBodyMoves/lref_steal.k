// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
//
// A C++ function template that moves out of its `T&` parameter leaves the
// Kairo argument moved-from: its instantiated body binds the argument to the
// `T&&` of a move constructor. One that only reads it borrows.

ffi "c++" import "Inputs/moves.h"

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
    steal(&h)
    return h.id
}

fn borrowed() -> i32 {
    var h = Res(7)
    look(&h)
    return h.id
}

fn main() -> i32 {
    return moved() + borrowed()
}

// --- lit wiring ---
// CHECK: lref_steal.k:24:12: error [SC052E]: 'h' is used after being moved
// CHECK: lref_steal.k:23:5: note {{.*}}: 'h' was moved here, by the call to 'steal'
// CHECK: moves.h:7:48: note {{.*}}: 'steal' moves it here
// CHECK-NOT: error
