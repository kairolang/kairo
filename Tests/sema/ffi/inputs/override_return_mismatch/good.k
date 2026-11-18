ffi "c++" import "b.h"

class D derives B {
    override fn val(self) -> i32 { return 2 }
    override fn self_(self) -> unsafe *D { return unsafe &self }
    override fn tick(self) { }
}

fn main() -> i32 {
    var d = D()
    return d.val() - 2
}
