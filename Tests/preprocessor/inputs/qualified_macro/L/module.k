// Not library c: a block named c in module L, which L/b.k does not import.
module c {
    pub macro m!() { 2 }
    pub fn g() -> i32 { return 2 }
}
