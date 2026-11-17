// SC358E per instance: a generic class with a destructor and no constructor
// whose category its argument decides. An instance over a move-only type
// cannot be moved, and is the error where it is used; one over a copyable
// type is accepted.

class Mv {
    pub var n: i32 = 0
    fn Mv(self) { }
    @move fn Mv(self, other: Self) {
        self.n = other.n
    }
}

class <T> H {
    pub var m: T
    fn op finally(self) { }
}

fn main() -> i32 {
    var a = H<i32>()
    var b = H<Mv>()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: move_dtor_no_ctor_instance.k:21:13: error [SC358E]: 'H<Mv>' is move-only and has a destructor but no constructor, so it cannot be moved: write a constructor or a '@move' constructor in 'H'
// CHECK-NEXT: move_dtor_no_ctor_instance.k:16:5: note {{.*}}: the destructor is declared here
// CHECK-NOT: error
