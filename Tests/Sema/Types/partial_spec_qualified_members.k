// The const-element partial specialization has only the members it
// declares: a writer of the primary is not a member of it.

class <T> Slice {
    var data: *T
    fn Slice(self, d: *T) { self.data = d }
    fn set(self, const v: T) { *self.data = v }
}

class <T> Slice<const T> {
    var data: *const T
    fn Slice(self, d: *const T) { self.data = d }
    fn get(const self) -> *const T { return self.data }
}

fn main() -> i32 {
    var x: i32 = 1
    var m = Slice<i32>(&x)
    m.set(2)
    var k = Slice<const i32>(&x)
    k.set(3)
// CHECK: partial_spec_qualified_members.k:[[@LINE-1]]:{{[0-9]+}}: error [R025E]: no member named 'set' in 'Slice'
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
