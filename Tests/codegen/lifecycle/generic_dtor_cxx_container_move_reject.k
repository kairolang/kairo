// A generic class over a C++ container of a MOVE type is MOVE per instance:
// assigning one instance moves it, so a later use is SC052E, while the COPY instance
// (`Bag<i32>`) copies and stays usable.

ffi "c++" import "vector"

class Mv {
    pub var n: i32 = 0
    fn Mv(self, n: i32) { self.n = n }
    @move fn Mv(self, other: Self) {
        self.n  = other.n
        other.n = 0
    }
}

class <T> Bag {
    pub var items: cxx::std::vector<T>
    fn Bag(self) { }
    fn op finally(self) { }
}

fn main() -> i32 {
    var c = Bag<i32>()
    var d = c
    var b = Bag<Mv>()
    var e = b
    var f = b
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error ['
// CHECK: generic_dtor_cxx_container_move_reject.k:27:13: error [SC052E]: 'b' is used after being moved
// CHECK: note [I900N]: 'b' was moved here, into 'e'
// CHECK: note [I900N]: assign a new value to 'b' before using it again
