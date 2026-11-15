// RUN: { %kairo %s --type-check-only --print-unchecked-assumptions -fno-strict-cxx-moves 2>&1 || true; } | %FileCheck %s
//
// A lambda that captures the object by reference and moves it moves it; one
// that only reads it does not. `o.*pd` is a member of `o`. In recursion, a
// function that reaches the move only through a caller still being answered
// gets the move as well, whichever of the two is asked first.

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

fn lambda_move() -> i32 {
    var h = Res(1)
    lambda_moves(&h)
    return h.id
}

fn lambda_read() -> i32 {
    var h = Res(2)
    lambda_reads(&h)
    return h.id
}

fn member_ptr() -> i32 {
    var h = Holder<Res>()
    member_ptr_moves(&h)
    return h.t.id
}

fn cycle_first() -> i32 {
    var h = Res(3)
    cyc_a(&h, 2)
    return h.id
}

fn cycle_second() -> i32 {
    var h = Res(4)
    cyc_b(&h, 2)
    return h.id
}

fn main() -> i32 {
    return 0
}

// --- lit wiring ---
// CHECK: lambda_and_recursion.k:25:12: error [SC052E]: 'h' is used after being moved
// CHECK: lambda_and_recursion.k:24:5: note {{.*}}: 'h' was moved here, by the call to 'lambda_moves'
// CHECK-NOT: lambda_and_recursion.k:31:{{.*}}error
// CHECK: lambda_and_recursion.k:37:12: error [SC052E]: 'h' is used after
// CHECK: lambda_and_recursion.k:43:12: error [SC052E]: 'h' is used after being moved
// CHECK: lambda_and_recursion.k:49:12: error [SC052E]: 'h' is used after being moved
// CHECK: lambda_and_recursion.k:48:5: note {{.*}}: 'h' was moved here, by the call to 'cyc_b'
// CHECK-NOT: unchecked assumption
