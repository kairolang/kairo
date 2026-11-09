// `start | self.dyn()->prev().range` -- a user `op |` whose right operand is
// duck-typed (no type) under a `<T: type>` mixin -- ICEd "user operator;
// OperatorLowering must rewrite it into a call". It is emitted as the C++
// operator expression and clang picks the instance's operator.

struct Rng {
    pub var a: i32 = 0;
    fn op | (const self, other: Rng) -> Rng {
        var r = Rng(); r.a = self.a + other.a; return r;
    }
}
class Tok {
    pub var range: Rng;
    fn Tok(self) { self.range = Rng(); self.range.a = 3; }
}
class Host derives P<Host> {
    fn prev(self) -> Tok { return Tok(); }
}
class <T: type> P {
    inline fn dyn(self) -> *T {
        return unsafe (&self as *T);
    }
    pub fn go(self) -> i32 {
        var start = Rng(); start.a = 4;
        var r = Rng();
        r = start | self.dyn()->prev().range;
        return r.a
    }
}
fn main() -> i32 {
    var h = Host();
    return h.go()
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo -fduck-generics %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
