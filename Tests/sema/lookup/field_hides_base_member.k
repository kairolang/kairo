// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// A field a class declares hides a base member of the same name, field or
// method, as in C++ (only overload sets merge). `self.ctx` in a class
// deriving one that also declares `ctx`, and a field `is_unsafe` beside a
// base's `is_unsafe()`, were R028E "ambiguous: it names more than one
// member reachable from here".
// CHECK-NOT: error

class Base {
    pub var ctx: i32 = 1
    fn is_unsafe(const self) -> bool { return false }
}

class Derived derives Base {
    pub var ctx: i64 = 2
    pub var is_unsafe: bool = true
    fn get(self) -> i64 { return self.ctx }
    fn flag(self) -> bool { return self.is_unsafe }
}
