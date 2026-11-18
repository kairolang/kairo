// A move-only class with a destructor and no constructor is a C++
// aggregate with no move: C++ declares none beside a destructor, and the
// move-only field leaves no copy to fall back on. It is an error at the
// class. A constructor, a `@move`, or no destructor each resolve it, and a
// copyable class of the same shape is accepted.

class Mv {
    pub var n: i32 = 0
    fn Mv(self) { }
    @move fn Mv(self, other: Self) {
        self.n = other.n
    }
}

class H {
    pub var m: Mv
    fn op finally(self) { }
}

class WithCtor {
    pub var m: Mv
    fn WithCtor(self) { }
    fn op finally(self) { }
}

class WithMove {
    pub var m: Mv
    @move fn WithMove(self, other: Self) = default
    fn op finally(self) { }
}

class NoDtor {
    pub var m: Mv
}

class Plain {
    pub var n: i32 = 0
    fn op finally(self) { }
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: move_dtor_no_ctor.k:15:1: error [SC358E]: 'H' is move-only and has a destructor but no constructor, so it cannot be moved: write a constructor or a '@move' constructor
// CHECK-NEXT: move_dtor_no_ctor.k:17:5: note {{.*}}: the destructor is declared here
// CHECK-NEXT: note {{.*}}: declare a constructor 'fn H(self)', or the move '@move fn H(self, other: Self) = default'
// CHECK-NOT: error
