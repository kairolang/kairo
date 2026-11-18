// XFAIL: *
// `return f` of a narrowed move-only nullable copies the payload instead of
// moving it: the program is rejected with CL001E ("call to implicitly-deleted
// copy constructor"). ownership.mdx (MOVE types, Last-use move optimization):
// a MOVE value that is not used again is moved, and nullables.mdx (Narrowing)
// reads a known non-null nullable as its `T`.

class Tracked {
    pub var id: i32
    pub fn Tracked(self, id: i32) { self.id = id }
    @move fn Tracked(self, other: Self) { self.id = other.id; other.id = 0 }
}
fn make(id: i32) -> Tracked? { if id > 0 { return Tracked(id) } return null }

fn pick(@move f: Tracked?) -> Tracked {
    if f? { return f }
    return Tracked(-1)
}

fn main() -> i32 {
    var r = pick(make(3))
    if r.id != 3 { return 1 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
