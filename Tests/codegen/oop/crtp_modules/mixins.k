pub interface Weighted {
    fn weight(const self) -> i32
}

// The bounded spelling: the cast is proven by `derives`, the call by `impl`.
pub class <X derives Counter<X> impl Weighted> Counter {
    pub var hits: i32 = 0
    pub fn bump(self) -> i32 {
        self.hits += 1
        return (&self as *X)->weight() + self.hits
    }
}

// The duck spelling: C++ checks the cast and the call per instance.
pub class <T: type> Tagged {
    pub var tag: i32 = 3
    pub fn tagged(const self) -> i32 { return self.tag * (&self as *const T)->weight() }
}
