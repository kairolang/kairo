// A generic record's member whose `requires` is false for an instance is
// dropped from that instance by C++ (its trailing requires-clause), so a
// transfer-then-read in its body is no use after move there. The instance
// move check skips it: `Box<Mv>` is not SC052E for `twice`, whose
// clause asks for a copyable T (as vector.k's resize(n, value) on [Mv]).
// Box<i32> meets the clause and its body runs; a member with no clause is
// still checked at Box<Mv>.

class Mv {
    var h: i32
    fn Mv(self) = default
    @move
    fn Mv(self, other: Self) = default
}

class <T> Box {
    var v: T
    fn Box(self, v: T) { self.v = v }

    fn twice(self) -> i32 requires __builtin_is_constructible<T, const T>() {
        var t = self.v
        var a = t
        var b = t
        return 7
    }
}

class <T> Bad {
    var v: T
    fn Bad(self, v: T) { self.v = v }

    fn twice(self) -> i32 {
        var t = self.v
        var a = t
        var b = t
        return 0
    }
}

fn main() -> i32 {
    var b = Box<Mv>(Mv())
    var c = Box<i32>(3)
    return c.twice()
}

fn bad() -> i32 {
    var d = Bad<Mv>(Mv())
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: in 'Box<Mv>'
// DIAG: requires_member_move_reuse.k:47:13: error [SC052E]: 't' is used after being moved in 'Bad<Mv>'
// DIAG-NOT: in 'Box<Mv>'
