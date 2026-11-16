// Corpus for Codegen/oop/param_base_xfile/use.k: the mixin and its bound
// live in this file; the arguments are the other file's.
pub class Base {
    pub var n: i32 = 3
    pub fn Base(self) { }
    pub virtual fn begin(self) -> i32 { return 1 }
    pub fn plain(self) -> i32 { return self.n }
    pub fn plain(self, k: i32) -> i32 { return self.n + k }
}

pub class <A derives Base> Hooked derives A {
    pub var hook: i32 = 100
    pub override fn begin(self) -> i32 { return A::begin(self) + self.hook }
    pub fn both(self) -> i32 { return self.plain() + self.plain(1) }
    pub fn plain(self, a: i32, b: i32) -> i32 { return a + b }
}

pub fn through(b: *Base) -> i32 { return b->begin() }
