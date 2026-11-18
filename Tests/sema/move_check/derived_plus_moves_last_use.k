// `a + b` through an `op +` derived from `op +=` moves a move-only left
// operand into the result when it is a local or a by-value parameter that
// nothing reads again on any path. Read again later (the next iteration of
// a loop included), or a place that is not such a local, it is a copy the
// type cannot make: SC182E, with the `.copy()` fix-it.

class S {
    pub var v: i32 = 0
    fn S(self, x: i32) { self.v = x }
    @move fn S(self, other: Self) { self.v = other.v }
    fn copy(const self) -> Self { return S(self.v) }
    fn op += (self, const o: S) { self.v += o.v }
}

class Box {
    pub var s: S
    fn Box(self) { self.s = S(1) }
}

fn last(a: S, b: S) -> S {
    return a + b
}

fn branches(c: bool) -> i32 {
    var s = S(1)
    if c {
        var t = s + S(2)
        return t.v
    }

    var u = s + S(3)
    return u.v
}

fn chain() -> S {
    var a = S(1)
    return a + S(2) + S(3)
}

fn reassigned(n: i32) -> i32 {
    var s = S(0)
    for var i = 0; i < n; ++i {
        s = s + S(1)
    }

    return s.v
}

fn later() -> i32 {
    var s = S(1)
    var t = s + S(2)
    return s.v + t.v
}

fn next_iteration(n: i32) -> i32 {
    var s = S(1)
    var t = S(0)
    for var i = 0; i < n; ++i {
        t = s + S(1)
    }

    return t.v
}

fn both_sides() -> i32 {
    var s = S(1)
    var t = s + s
    return t.v
}

fn places(const k: S, b: Box) -> i32 {
    var t = b.s + S(1)
    var u = k + S(1)
    return t.v + u.v
}

fn element(@inout v: [S; 2]) -> i32 {
    var t = v[0] + S(1)
    return t.v
}

fn loop_local(n: i32) -> i32 {
    var total = 0
    for var i = 0; i < n; ++i {
        var p = S(1)
        var q = p + S(2)
        total += q.v
    }

    return total
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK:      derived_plus_moves_last_use.k:51:13: error [SC182E]: cannot copy a value of type 'S'
// CHECK-NEXT: derived_plus_moves_last_use.k:51:13: note [I900N]: '+' is derived from 'op +=': it copies its left operand 's', applies '+=' to the copy and yields it; write 's += ...' to change it in place. 's' is read again later, so it cannot be moved into the result
// CHECK-NEXT: derived_plus_moves_last_use.k:51:14: note [I900N]: 'S' has a 'copy' method: write 's.copy()' for an explicit copy
// CHECK-NEXT: fix-it:"{{.*}}":{51:14-51:14}:".copy()"
// CHECK-NEXT: derived_plus_moves_last_use.k:52:12: note [I900N]: read again here
// CHECK:      derived_plus_moves_last_use.k:59:13: error [SC182E]: cannot copy a value of type 'S'
// CHECK-NEXT: derived_plus_moves_last_use.k:59:13: note [I900N]: {{.*}} 's' is read again later, so it cannot be moved into the result
// CHECK:      fix-it:"{{.*}}":{59:14-59:14}:".copy()"
// CHECK-NEXT: derived_plus_moves_last_use.k:59:13: note [I900N]: read again here
// CHECK:      derived_plus_moves_last_use.k:67:13: error [SC182E]: cannot copy a value of type 'S'
// CHECK-NEXT: derived_plus_moves_last_use.k:67:13: note [I900N]: {{.*}} The right operand reads 's' too, so it cannot be moved into the result
// CHECK:      fix-it:"{{.*}}":{67:14-67:14}:".copy()"
// CHECK:      derived_plus_moves_last_use.k:72:13: error [SC182E]: cannot copy a value of type 'S'
// CHECK-NEXT: derived_plus_moves_last_use.k:72:13: note [I900N]: {{.*}} 'b.s' is not a local variable or by-value parameter read for the last time here, so it cannot be moved into the result
// CHECK:      fix-it:"{{.*}}":{72:16-72:16}:".copy()"
// CHECK:      derived_plus_moves_last_use.k:73:13: error [SC182E]: cannot copy a value of type 'S'
// CHECK-NEXT: derived_plus_moves_last_use.k:73:13: note [I900N]: {{.*}} 'k' is not a local variable
// CHECK:      fix-it:"{{.*}}":{73:14-73:14}:".copy()"
// CHECK:      derived_plus_moves_last_use.k:78:13: error [SC182E]: cannot copy a value of type 'S'
// CHECK-NEXT: derived_plus_moves_last_use.k:78:13: note [I900N]: {{.*}} 'v[0]' is not a local variable or by-value parameter read for the last time here, so it cannot be moved into the result
// CHECK:      fix-it:"{{.*}}":{78:17-78:17}:".copy()"
