// `a + b` derived from `op +=` in a generic body, where an operand's type is
// the instance's: a temporary left operand moves into the result. A MOVE
// type has no copy, so the result is built from the operand, not copied.

class M {
    pub var n: i32 = 0
    pub fn M(self, n: i32) {
        self.n = n
    }

    @move pub fn M(self, other: Self) {
        self.n = other.n
        other.n = 0
    }

    pub fn op += (self, const o: M) {
        self.n += o.n
    }
}

fn <T> sum(const t: T) -> T {
    return T(40) + t
}

fn main() -> i32 {
    var m = M(2)
    return sum(m).n
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe; test $? -eq 42
