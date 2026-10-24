// build: kairo F11-private-field-access-reaches-clang.k -o f22   (expect a Kairo access error)
class A {
    var x: i32              // private by default
    pub fn A(self) { self.x = 1 }
}

fn main() -> i32 {
    var a = A()
    return a.x              // no Kairo diagnostic; clang reports CL001E
}
