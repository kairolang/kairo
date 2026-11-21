// A move constructor with a body that only reads `other`, in a class with a
// destructor and a pointer field, leaves both objects holding the address.
// Resetting the source (or handing it to a call) is accepted.

class Reads {
    var p: unsafe *i32

    fn Reads(self, v: unsafe *i32) { self.p = v }
    @move fn Reads(self, other: Self) { self.p = other.p }
    fn op finally(self) { }
}

class Resets {
    var p: i32

    fn Resets(self, v: i32) { self.p = v }
    @move fn Resets(self, other: Self) {
        self.p  = other.p
        other.p = 0
    }
    fn op finally(self) { }
}

class Defaulted {
    var p: i32

    fn Defaulted(self, v: i32) { self.p = v }
    @move fn Defaulted(self, other: Self) = default
    fn op finally(self) { }
}

class NoDtor {
    var p: i32

    fn NoDtor(self, v: i32) { self.p = v }
    @move fn NoDtor(self, other: Self) { self.p = other.p }
}

fn steal_(@inout dst: i32, @inout src: i32) { }

class Hands {
    var p: i32

    fn Hands(self, v: i32) { self.p = v }
    @move fn Hands(self, other: Self) { steal_(&self.p, &other.p) }
    fn op finally(self) { }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --error-format=basic 2>&1 || true; } | %FileCheck %s
// CHECK: move_ctor_never_writes_source.k:9:{{[0-9]+}}: warning [SC001W]: the '@move' constructor of 'Reads' never writes 'other'
// CHECK-NOT: warning [SC001W]
