pub interface Named {
    fn name(const self) -> i32
}

pub class <T impl Named> Holder {
    pub var v: T
    pub fn Holder(self, x: T) { self.v = x }
    pub fn get(const self) -> i32 { return self.v.name() }
}

pub class Good {
    pub var k: i32
    pub fn Good(self) { self.k = 0 }
    pub fn Good(self, k: i32) { self.k = k }
    pub fn name(const self) -> i32 { return self.k }
}
