// build: kairo F10-constructor-field-assignment-is-not-initialization.k -o f21   (expect exit 4)
class Inner {
    pub var v: i32
    pub fn Inner(self, v: i32) { self.v = v }
}

class Outer {
    pub var a: Inner
    pub fn Outer(self, x: i32) { self.a = Inner(x) }   // first assignment should initialize `a`
}

fn main() -> i32 {
    var o = Outer(4)
    return o.a.v
}
