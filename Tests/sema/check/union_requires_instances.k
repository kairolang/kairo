// A generic union's `requires` clause is evaluated at each instance, as a
// struct's is: W<Ok> is accepted, W<No> is rejected at its use.

interface Same {
    fn op ==(const self, o: Self) -> bool
}

union <T> W requires T impl Same {
    var value: T
    var raw:   u64
}

struct Ok impl Same {
    var x: i32

    fn op ==(const self, o: Ok) -> bool { return self.x == o.x }
}

struct No {
    var x: i32
}

fn main() -> i32 {
    var w: W<Ok>
    var v: W<No>
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: :24:{{[0-9]+}}: error
// CHECK: union_requires_instances.k:25:12: error [SC162E]: 'No' does not conform to 'Same': no member 'op ==' with the requirement's signature
// CHECK: union_requires_instances.k:8:22: note [I900N]: required by this bound
// CHECK-NOT: error
