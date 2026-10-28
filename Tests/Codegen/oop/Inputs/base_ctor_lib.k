// Corpus for Codegen/oop/base_ctor_cross_module.k: bases in their own
// module, each with only a constructor that takes arguments.
pub class Shape {
    prot var sides: i32
    pub fn Shape(self, sides: i32) { self.sides = sides }
    pub fn count(const self) -> i32 { return self.sides }
}

pub class <T> Holder {
    prot var held: T
    pub fn Holder(self, t: T) { self.held = t }
    pub fn get(const self) -> T { return self.held }
}
