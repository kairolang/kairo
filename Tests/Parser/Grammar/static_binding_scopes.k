// `static` introduces a binding everywhere a binding is legal. It is only an
// abi modifier when a `fn` head follows, so it must not be swallowed as one.
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
static TOP: i32 = 1
static thread TOP_TL: i32 = 2
static PTR: fn (usize, usize) -> *void

module m {
    static IN_MODULE: i32 = 3
}

class C {
    static COUNT: i32 = 0
    static fn make() -> i32 { return 1 }
    fn method(self) -> i32 { return C::COUNT }
}

fn Test() {
    static LOCAL: i32 = 4
}
