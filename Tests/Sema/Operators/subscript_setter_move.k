// The right side of `x[k] = v` through the setter form of `op []=` is an
// argument: MoveCheck passes it as the setter's value parameter takes it.
//
//   - By value: a move-only lvalue is moved into the parameter, so a later
//     use is SC052E, and assigning it again makes it usable.
//   - `const v: V` borrows: the value stays live.
//   - An element of a container is not moved out into another element.

class Str {
    pub var n: i32 = 0
    fn Str(self) { }
    fn Str(self, n: i32) { self.n = n }
    @move fn Str(self, other: Self) { self.n = other.n; other.n = 0 }
}

class Bag {
    var d: [Str; 2]
    fn Bag(self) { }
    fn op [] (const self, i: usize) -> *const Str { return &self.d[i] }
    fn op []= (self, i: usize, v: Str) { self.d[i] = v }
}

class Peek {
    var d: [Str; 2]
    var seen: i32 = 0
    fn Peek(self) { }
    fn op [] (const self, i: usize) -> *const Str { return &self.d[i] }
    fn op []= (self, i: usize, const v: Str) { self.seen = v.n }
}

fn moved() -> i32 {
    var b = Bag()
    var s = Str(3)
    b[0] = s
    return s.n
}

fn borrowed() -> i32 {
    var p = Peek()
    var s = Str(3)
    p[0] = s
    return s.n
}

fn revived() -> i32 {
    var b = Bag()
    b[0] = Str(4)
    var s = Str(5)
    b[1] = s
    s = Str(6)
    return s.n
}

fn element() {
    var b = Bag()
    b[0] = b[1]
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: {{error|warning}}
// CHECK: subscript_setter_move.k:35:12: error [SC052E]: 's' is used after being moved
// CHECK-NEXT: subscript_setter_move.k:34:12: note [{{.*}}]: 's' was moved here, into a by-value parameter
// CHECK-NEXT: subscript_setter_move.k:35:12: note [{{.*}}]: assign a new value to 's' before using it again
// CHECK-NOT: {{error|warning}}
// CHECK: subscript_setter_move.k:56:12: error [SC182E]: cannot copy a value of type 'Str': it declares a move constructor and no copy constructor
// CHECK-NEXT: subscript_setter_move.k:56:12: note [{{.*}}]: 'b[1]' is an element of a container, and moving an element out into another element is not supported; swap them, or move through a local
// CHECK-NOT: {{error|warning}}
