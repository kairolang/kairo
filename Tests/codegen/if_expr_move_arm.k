// An if-expression is a value: an arm that names a place of a MOVE type
// moves into it, since C++'s `?:` would copy an lvalue operand and a MOVE
// type has no copy.

class M {
    pub var n: i32 = 0
    pub fn M(self, n: i32) {
        self.n = n
    }

    @move pub fn M(self, other: Self) {
        self.n = other.n
        other.n = 0
    }
}

fn pick(c: bool) -> M {
    var m = M(4)
    return if (c) => (m) else => M(2)
}

fn main() -> i32 {
    var k = M(5)
    var j = if (k.n > 1) => (k) else => M(3)
    return pick(true).n * 10 + j.n
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe; test $? -eq 45
