// XFAIL: *
// Moving a move-only nullable into another nullable is rejected: both
// `var d: Tracked? = c` (CL001E, "call to deleted constructor of
// 'builtin::Null<Tracked>'") and `b = a` (CL001E, "overload resolution
// selected deleted operator '='") fail, while the same transfers of a plain
// `Tracked` (`var y = x`, `y = x`) move. ownership.mdx (MOVE types):
// assignment and initialisation from a binding move a MOVE value, and a type
// holding a MOVE type is MOVE.

class Tracked {
    pub var id: i32
    pub fn Tracked(self, id: i32) { self.id = id }
    @move fn Tracked(self, other: Self) { self.id = other.id; other.id = 0 }
}
fn make(id: i32) -> Tracked? { if id > 0 { return Tracked(id) } return null }

fn main() -> i32 {
    var c: Tracked? = Tracked(1)
    var d: Tracked? = c
    var a: Tracked? = Tracked(2)
    var b: Tracked? = null
    b = a
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
