// build: kairo F13-generic-field-default-reads-sibling-gated.k -o f24   (expect exit 2)
class <T> G {
    pub var a: i32 = 1
    pub var b: i32 = a + 1      // SC116E today: the C++ spelling of `a` lacks G's arguments
    pub fn G(self) { }
}

fn main() -> i32 {
    var g = G<i32>()
    return g.b
}
