// left.k and right.k import each other. Each calls a function of the other
// that leaves a part of its argument moved-from, and uses that part.
import right::*

pub class Str {
    pub var n: i32 = 0
    pub fn Str(self) { }
    @move pub fn Str(self, other: Self) { self.n = other.n; other.n = 0 }
}

pub class Holder {
    pub var a: Str
    pub var b: Str
    pub fn Holder(self) { }
    pub fn take_a(self) -> Str { return self.a }
}

pub fn left_uses_right() -> i32 {
    var h = Holder()
    var b = drain_b(&h)
    return h.b.n
}
