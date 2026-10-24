// build: kairo F4-assignment-through-base-lvalue-slices.k   (compiles silently today; expect a diagnostic at *b = from)
class Base {
    pub var v: i32 = 0
    pub fn Base(self) { }
    pub fn Base(self, v: i32) { self.v = v }
    @copy
    fn Base(self, const other: Self) { self.v = other.v }
}

class Derived derives Base {
    pub var w: i32 = 0
    pub fn Derived(self, v: i32, w: i32) { self.v = v; self.w = w }
}

fn assign(b: *Base, const from: Base) {
    *b = from               // destroys and rebuilds a Base in place, whatever *b really is
}

fn main() -> i32 {
    var d = Derived(1, 2)
    assign(&d, Base(7))     // replaces the Base subobject of a Derived in place: UB
    return d.v + d.w
}
