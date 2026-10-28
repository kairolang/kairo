// Corpus for Codegen/oop/access_derives_narrowing.k: classes deriving a
// base `priv` and `prot`, used from another module.
pub class V {
    pub var x: i32 = 1
    pub fn f(const self) -> i32 { return 10 }
    pub fn f(const self, k: i32) -> i32 { return k }
    prot fn g(const self) -> i32 { return 20 }
    pub fn V(self) { }
    virtual fn k(self) -> i32 { return 0 }
}

pub class S derives priv V {
    pub fn S(self) { }
    pub fn sum(const self) -> i32 { return self.x + self.f() + self.f(5) + self.g() }
}

pub class P derives prot V {
    pub fn P(self) { }
}

// The declaring file reaches V's members through S.
pub fn lib_sum(s: *S) -> i32 { return s->x + s->f() }
