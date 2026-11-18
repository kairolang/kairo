pub class Pubby {
    pub var n: i64 = 0
    pub fn Pubby(self, n: i64) { self.n = n }
    @implicit pub fn op as(const self) -> i64 { return self.n }
}

pub class Secret {
    pub var n: i64 = 0
    pub fn Secret(self, n: i64) { self.n = n }
    @implicit priv fn op as(const self) -> i64 { return self.n }
}

pub fn inside(s: Secret) -> i64 {
    var x: i64 = s
    return x + (s as i64)
}
