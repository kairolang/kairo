// After a local is moved as a whole, every way to reach one of its parts
// other than storing a new value is a use after the move (SC052E): a
// method call on a field, a compound assignment to a field, a field passed
// `@inout`, a pointer to a field, and `finally()` on the local. `finally()`
// on a field is SC305E, as anywhere. A plain store into a field is
// accepted (destructive_moves_part_store.k shows the object is destroyed).

class R {
    var id: i32 = 0
    fn R(self, id: i32) { self.id = id }
    @move fn R(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
    fn bump(self) { self.id += 1 }
    fn op finally(self) { }
}

class Pair {
    var a: R
    var b: R
    var n: i32 = 0
    fn Pair(self) {
        self.a = R(1)
        self.b = R(2)
    }
}

fn take(p: Pair) { }

fn fill(@inout r: R) { r = R(9) }

fn method_on_part() {
    var p = Pair()
    take(p)
    p.b.bump()
}

fn compound_on_part() {
    var p = Pair()
    take(p)
    p.n += 1
}

fn inout_part() {
    var p = Pair()
    take(p)
    fill(&p.b)
}

fn pointer_to_part() {
    var p = Pair()
    take(p)
    var *q = &p.b
}

fn finally_whole() {
    var p = Pair()
    take(p)
    p.finally()
}

fn finally_part() {
    var p = Pair()
    p.b.finally()
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error
// DIAG: part_use_after_whole_move.k:36:5: error [SC052E]: 'p' is used after being moved
// DIAG: part_use_after_whole_move.k:42:5: error [SC052E]: 'p' is used after being moved
// DIAG: part_use_after_whole_move.k:48:11: error [SC052E]: 'p' is used after being moved
// DIAG: part_use_after_whole_move.k:54:15: error [SC052E]: 'p' is used after being moved
// DIAG: part_use_after_whole_move.k:60:5: error [SC052E]: 'p' is used after being moved
// DIAG: part_use_after_whole_move.k:65:5: error [SC305E]: finally() has no effect on 'p.b'; only a local variable declared in this body can be ended early
