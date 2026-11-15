// Corpus for Codegen/oop/access_unmarked_include.k: a file under no
// module.k whose class has a method with no visibility written (so `priv`),
// called from the file's `pub inline` function, which a C++ host compiles
// in its own TU.
pub class Gauge {
    pub fn Gauge(self) { }
    fn peek(const self) -> i32 { return 7 }
    pub fn open(const self) -> i32 { return self.peek() }
}

pub inline fn read(g: *Gauge) -> i32 { return g->peek() }
