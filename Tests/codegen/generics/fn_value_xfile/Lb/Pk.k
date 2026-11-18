pub interface Big { fn big(const self) -> i32 }

pub class W impl Big {
    pub var n: i32
    pub fn W(self, n: i32) { self.n = n }
    pub fn big(const self) -> i32 = self.n
}

pub fn <T impl Big> pick(x: T) -> i32 { return x.big() + 10 }
