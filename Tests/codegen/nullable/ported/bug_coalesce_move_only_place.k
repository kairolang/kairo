// `t ?? d` with a move-only `T` and a nullable local on the left copies the
// payload instead of moving it (CL001E, "call to implicitly-deleted copy
// constructor"); with a call result on the left it moves. ownership.mdx
// (MOVE types): a MOVE value that is not used again is moved.

class Tracked {
    pub var id: i32
    pub fn Tracked(self, id: i32) { self.id = id }
    @move fn Tracked(self, other: Self) { self.id = other.id; other.id = 0 }
}
fn make(id: i32) -> Tracked? { if id > 0 { return Tracked(id) } return null }

fn pick(t: Tracked?) -> i32 {
    var r = t ?? Tracked(100)
    return r.id
}

fn main() -> i32 {
    if pick(make(3)) != 3 { return 1 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
