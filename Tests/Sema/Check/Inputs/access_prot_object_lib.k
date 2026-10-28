// Corpus for Sema/Check/access_prot_object.k: a base whose protected
// members a subclass in another module reaches, rightly and wrongly.
pub class Base {
    prot var hits: i32 = 0
    prot static scale: i32 = 3
    prot fn bump(self, n: i32) { self.hits += n }
    prot fn Base(self, h: i32) { self.hits = h }
    pub fn Base(self) { }
    prot class Inner { pub var k: i32 = 1 }
}

// The declaring file reaches them through anything.
pub fn lib_reads(b: *Base) -> i32 {
    var c = Base(4)
    b->bump(1)
    return b->hits + c.hits
}
