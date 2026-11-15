// RUN: { %kairo %s --type-check-only --print-unchecked-assumptions 2>&1 || true; } | %FileCheck %s --allow-empty
//
// A COPY value is never left moved-from by a C++ call, whatever its body
// does: taking it out of its storage copies it. Nothing is assumed either.

ffi "c++" import "Inputs/moves.h"

class Pt {
    pub var x: i32 = 0
    fn Pt(self, x: i32) {
        self.x = x
    }
}

fn main() -> i32 {
    var a = Pt(1)
    steal(&a)
    var b = Pt(2)
    opaque(&b)
    return a.x + b.x
}

// --- lit wiring ---
// CHECK-NOT: error
// CHECK-NOT: unchecked assumption
