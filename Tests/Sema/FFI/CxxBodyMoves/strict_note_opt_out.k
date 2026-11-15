// RUN: { %kairo %s --type-check-only -fstrict-cxx-moves 2>&1 || true; } | %FileCheck %s
//
// Under -fstrict-cxx-moves a C++ call whose body cannot be inspected leaves
// its MOVE argument moved-from. The note says why the body could not be
// inspected and names the flag that takes the call to borrow instead.

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

fn main() -> i32 {
    var h = Res(7)
    opaque(&h)
    return h.id
}

// --- lit wiring ---
// CHECK: strict_note_opt_out.k:24:12: error [SC052E]: 'h' is used after being moved
// CHECK: strict_note_opt_out.k:23:5: note {{.*}}: 'h' was moved here, by the call to 'opaque', whose body cannot be inspected
// CHECK: moves.h:{{[0-9]+}}:{{[0-9]+}}: note {{.*}}: not inspected: its body is not visible; with -fno-strict-cxx-moves the call borrows it, on an unchecked assumption
// CHECK-NOT: error
