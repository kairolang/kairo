// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
//
// A non-const C++ method whose body moves `*this` out (`return
// std::move(*this)`) leaves its receiver moved-from; one that only changes
// it does not.

ffi "c++" import "inputs/moves.h"

fn taken() -> i32 {
    var b = cb::Box(3)
    var c = b.take()
    return b.get() + c.get()
}

fn poked() -> i32 {
    var b = cb::Box(3)
    b.poke()
    return b.get()
}

fn main() -> i32 {
    return taken() + poked()
}

// --- lit wiring ---
// CHECK: method_this.k:12:12: error [SC052E]: 'b' is used after being moved
// CHECK: method_this.k:11:13: note {{.*}}: 'b' was moved here, by the call to 'take'
// CHECK: moves.h:{{[0-9]+}}:{{[0-9]+}}: note {{.*}}: 'cb::Box::take' moves it here
// CHECK-NOT: error
