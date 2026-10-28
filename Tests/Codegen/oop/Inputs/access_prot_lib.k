// Corpus for Codegen/oop/access_prot_cross_module.k: a base whose
// protected members a subclass in another module uses.
pub class Base {
    prot var hits: i32 = 0
    prot static scale: i32 = 3
    prot fn bump(self, n: i32) { self.hits += n }
    prot fn Base(self, h: i32) { self.hits = h }
    pub fn Base(self) { }
    pub fn read(const self) -> i32 { return self.hits }
}

pub class <T> Slot {
    prot var value: T
    pub fn Slot(self, v: T) { self.value = v }
    prot fn peek(const self) -> T { return self.value }
}
