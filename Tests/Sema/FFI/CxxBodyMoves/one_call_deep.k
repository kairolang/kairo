// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
//
// `outer` hands its `T&` on to `inner_take`, which moves it: the walk
// follows the reference into the callee. `outer_look` hands it to a function
// that only reads it, and `forwards` to one whose `std::forward<T&>` copies.

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

fn deep() -> i32 {
    var h = Res(7)
    outer(&h)
    return h.id
}

fn reads() -> i32 {
    var h = Res(7)
    outer_look(&h)
    return h.id
}

fn copies() -> i32 {
    var h = Res(7)
    forwards(&h)
    return h.id
}

fn main() -> i32 {
    return deep() + reads() + copies()
}

// --- lit wiring ---
// CHECK: one_call_deep.k:24:12: error [SC052E]: 'h' is used after being moved
// CHECK: one_call_deep.k:23:5: note {{.*}}: 'h' was moved here, by the call to 'outer'
// CHECK: moves.h:16:{{[0-9]+}}: note {{.*}}: 'inner_take' moves it here, called from 'outer'
// CHECK-NOT: error
