// A container whose `@copy` constructor carries a `requires` on its
// element is COPY only where that clause holds: `[Mo]` of a move-only
// `Mo` meets no copy bound, as `Mo` itself does not, and Sema says so
// before the C++ step.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s

interface Copyable {
    @copy fn Copyable(self, const other: Self)
}

class Mo {
    pub var x: i32

    fn Mo(self) {
        self.x = 1
    }

    @move fn Mo(self, other: Self) {
        self.x = other.x
    }
}

fn <T impl Copyable> dup(const t: T) -> T {
    return t
}

fn main() -> i32 {
    var a: [i32] = [1]
    var b = dup(a)
    var v: [Mo] = []
    // CHECK: copy_bound_on_dropped_copy.k:[[@LINE+1]]:13: error [SC162E]: '[Mo]' does not conform to 'Copyable': '[Mo]' is not a COPY type
    var w = dup(v)
    // CHECK: note [I900N]: required by this bound
    // CHECK: note [I900N]: the constructor is required here
    // CHECK: vector.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: '[Mo]' declares a copy constructor, but its requirements do not hold here: 'Mo' cannot be copied
    var vv: [[i32]] = []
    var ww = dup(vv)
    return 0
}
// CHECK-NOT: error
