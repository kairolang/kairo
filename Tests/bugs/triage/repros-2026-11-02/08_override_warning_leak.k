// A virtual override.
// Expected: no diagnostic (Kairo has no `override` keyword, so the user can't
// act on one). Exit 6.
// Actual: clang's C505W "'area' overrides a member function but is not
// marked 'override'" reaches the user. Emit `override` on the C++ side for
// every member that overrides a base virtual.
class Shape {
    virtual fn area(const self) -> i64 { return 0 }
    virtual fn op delete(self) { }
}

class Rect derives Shape {
    var w: i64
    var h: i64
    fn Rect(self, w: i64, h: i64) { self.w = w; self.h = h }
    fn area(const self) -> i64 { return self.w * self.h }
}

fn main() -> i32 {
    var s: *Shape = @create<Rect>(2, 3)
    var a = s->area()
    @destroy(s)
    return a as i32   // exit 6
}
