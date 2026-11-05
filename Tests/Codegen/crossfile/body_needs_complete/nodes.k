// Imported by app.k through writer.k, not a test of its own.
ffi "c++" import "vector";

pub class Base {
    pub var k: i32 = 1
    fn Base(self) {}
}
pub class Sub derives Base {
    pub var z: i32 = 2
    fn Sub(self) {}
}
pub struct Elem { pub var v: i32; pub var w: i32 }
pub class Holder {
    pub var items: cxx::std::vector<Elem>
    fn Holder(self) {}
}
pub fn <T: type> probe(p: unsafe *Base) -> i32 { return T::tag(); }
pub class Tagged {
    pub var q: i32 = 0
    fn Tagged(self) {}
    pub static fn tag() -> i32 { return 3; }
}
