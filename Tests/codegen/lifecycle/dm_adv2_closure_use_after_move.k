// A closure that captures a local of a MOVE class takes it: a second closure
// or any later read of the local is a use after the move.
class R {
    var id: i32 = 0
    fn R(self, id: i32) { self.id = id }
    @move fn R(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op finally(self) { }
}

fn twice() {
    var a = R(1)
    var f = fn () -> i32 { return a.id }
    var g = fn () -> i32 { return a.id }
}

fn later() {
    var a = R(2)
    var f = fn () -> i32 { return a.id }
    var n = a.id
}

fn revived() {
    var a = R(3)
    var f = fn () -> i32 { return a.id }
    a = R(4)
    var n = a.id
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: error [SC052E]: 'a' is used after being moved
// CHECK: note [I900N]: 'a' was moved here, into the closure that captures it
// CHECK: error [SC052E]: 'a' is used after being moved
// CHECK: note [I900N]: 'a' was moved here, into the closure that captures it
// CHECK-NOT: error
