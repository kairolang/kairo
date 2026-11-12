// Members and a whole class declared by `pub macro`s, for app.k.
pub macro getter!() {
    fn get(const self) -> i32 { return self.v }
}
pub macro field!() {
    var extra: i32 = 30
}
pub macro adder!() {
    fn op + (const self, o: Self) -> i32 { return self.v + o.v }
}
// A `pub` member with nested blocks: `pub` and every `{` / `}` of the body
// come from this file.
pub macro clamp!() {
    pub fn clamp(const self, hi: i32) -> i32 {
        if self.v > hi {
            return hi
        }
        for var i = 0; i < 1; ++i {
            if i == 0 { return self.v }
        }
        return 0
    }
}
pub macro holder!() {
    pub class Holder {
        var n: i32 = 4
        fn twice(const self) -> i32 { return self.n * 2 }
    }
}
pub macro secret!() {
    priv fn hidden(const self) -> i32 { return self.v * 2 }
}
// A macro whose body invokes another one: `got`'s tokens are wrapped twice.
pub macro inner_got!() {
    fn got(const self) -> i32 { if self.v > 0 { return self.v + 1 } return 0 }
}
pub macro outer_got!() {
    inner_got!()
}
// An `ffi "c"` function: the walk passes `ffi` and `"c"` through itself.
pub macro cadd!() {
    ffi "c" fn kadd(x: i32, y: i32) -> i32 { return x + y }
}
