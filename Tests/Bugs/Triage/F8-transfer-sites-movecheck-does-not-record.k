// build: kairo F8-transfer-sites-movecheck-does-not-record.k   (expect each site moved and exit 0)
class Str {
    pub var n: i32 = 0
    fn Str(self) { }
    fn Str(self, n: i32) { self.n = n }
    @move fn Str(self, other: Self) { self.n = other.n; other.n = 0 }
}

class Acc {
    pub var n: i32 = 0
    fn Acc(self) { }
    fn op += (self, s: Str) { self.n += s.n }
    fn op [] (self, s: Str) -> i32 { return s.n }
}

class Pair { pub var a: Str  pub var b: Str }

fn first(p: Pair) -> Str = p.a                      // expression body: not moved
fn <T> relay(x: T) -> i32 { var y = x; return 0 }   // generic body: not moved

fn main() -> i32 {
    var acc = Acc()
    var s = Str(1)
    acc += s                                        // compound-assignment operand: not moved
    var t = Str(2)
    var r = acc[t]                                  // subscript operand: not moved
    var p = Pair()
    r += first(p).n
    r += relay<Str>(Str(3))
    return r - 2
}
