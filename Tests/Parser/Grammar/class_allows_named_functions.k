// The struct rule must not leak into classes.
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
class C {
    var a: i32
    fn C(self, a: i32) { self.a = a }
    fn named(self) -> i32 { return self.a }
    static fn make() -> i32 { return 0 }
    fn op == (self, o: Self) -> bool = self.a == o.a
    fn op delete (self) { }
}
