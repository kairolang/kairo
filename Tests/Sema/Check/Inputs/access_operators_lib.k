// Corpus for Sema/Check/access_operators.k: a class whose operators carry
// every visibility, used from another module.
pub class Num {
    pub var v: i32 = 0
    pub fn Num(self, v: i32) { self.v = v }
    priv fn op +(const self, o: Num) -> Num { return Num(self.v + o.v) }
    prot fn op -(const self, k: i32) -> Num { return Num(self.v - k) }
    pub fn op *(const self, o: Num) -> Num { return Num(self.v * o.v) }
    priv fn op [](const self, i: i32) -> i32 { return self.v + i }
    priv fn op ==(const self, o: Num) -> bool { return self.v == o.v }
    priv fn op %=(self, k: i32) { self.v = self.v % k }
    priv fn op -(const self) -> Num { return Num(0 - self.v) }
}

// The declaring file sees all of them.
pub fn lib_sum(a: Num, b: Num) -> i32 {
    var c = a + b
    c %= 3
    if c == b { return 0 }
    return (-c)[1] + (a - 2).v
}
