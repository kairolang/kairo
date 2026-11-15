// RUN: { %kairo %s --type-check-only --print-unchecked-assumptions -fno-strict-cxx-moves 2>&1 || true; } | %FileCheck %s
// RUN: { %kairo %s --type-check-only -fstrict-cxx-moves 2>&1 || true; } | %FileCheck %s --check-prefix=STRICT
//
// A C++ function whose body cannot be inspected -- declared only, or
// defined in a header the Kairo file does not import by name -- borrows its
// `T&` argument under -fno-strict-cxx-moves, on an assumption the build
// lists. -fstrict-cxx-moves (the default) takes such a call at its worst:
// the argument is moved-from, and the read after it is an error.

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

fn declared_only() -> i32 {
    var h = Res(7)
    opaque(&h)
    return h.id
}

fn included_only() -> i32 {
    var h = Res(7)
    via_inner(&h)
    return h.id
}

fn main() -> i32 {
    return declared_only() + included_only()
}

// --- lit wiring ---
// CHECK-NOT: error
// CHECK: no_body_assumed.k:26:5: unchecked assumption: 'opaque' is assumed not to move out of 'h': its body is not visible
// CHECK: no_body_assumed.k:32:5: unchecked assumption: 'via_inner' is assumed not to move out of 'h': it passes it to 'inner_steal', whose body is not visible
// CHECK-NOT: error

// STRICT: no_body_assumed.k:27:12: error [SC052E]: 'h' is used after being moved
// STRICT: no_body_assumed.k:26:5: note {{.*}}: 'h' was moved here, by the call to 'opaque', whose body cannot be inspected and is taken to move it under -fstrict-cxx-moves
// STRICT: note {{.*}}: not inspected: its body is not visible
// STRICT: no_body_assumed.k:33:12: error [SC052E]: 'h' is used after being moved
// STRICT: note {{.*}}: not inspected: it passes it to 'inner_steal', whose body is not visible
