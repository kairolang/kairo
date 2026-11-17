// Three copies of a move-only value that Sema accepted and clang then
// rejected (CL001E). Each is SC182E, at the copy.
//
// (a) `a + b` through an `op +` derived from `op +=` copies its left
//     operand (operator-overloading.mdx, Compound assignment). A temporary
//     left operand is built in the copy's place and is fine.
// (b) `return self.t` in a `const self` method: a const place cannot be
//     moved from, and the type has no copy. Only the const case is touched:
//     a non-const `self` field is moved out silently today (not covered
//     here).
// (c) a map literal of move-only elements: the map copies each element
//     out of the literal's backing array, which the library cannot do for
//     such a type yet. A vector literal moves its elements in: accepted.

class M {
    pub var v: i32 = 0
    fn M(self, x: i32) { self.v = x }
    @move fn M(self, other: Self) { self.v = other.v; other.v = 0 }
    fn op += (self, const o: M) { self.v += o.v }
}

class Tok {
    pub var id: i32 = 0
    fn Tok(self) { self.id = 3 }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

class H {
    pub var t: Tok
    fn H(self) { self.t = Tok() }
    fn peek(const self) -> Tok { return self.t }
}

fn main() -> i32 {
    var a = M(1)
    var b = M(2)
    var c = a + b
    var d = M(5) + b
    var v: [Tok] = [Tok(), Tok()]
    var m: {i32: Tok} = {1: Tok()}
    return c.v + d.v
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: move_only_late_copies.k:31:41: error [SC182E]: cannot copy a value of type 'Tok': it declares a move constructor and no copy constructor
// CHECK: move_only_late_copies.k:31:41: note [I900N]: 'self.t' is const, so the transfer out of the function cannot move it, and moving is the only transfer its type has
// CHECK: move_only_late_copies.k:37:13: error [SC182E]: cannot copy a value of type 'M': it declares a move constructor and no copy constructor
// CHECK: move_only_late_copies.k:37:13: note [I900N]: '+' is derived from 'op +=': it copies its left operand 'a', applies '+=' to the copy and yields it; write 'a += ...' to change it in place
// CHECK: move_only_late_copies.k:40:25: error [SC182E]: a map literal of 'Tok' elements cannot be built yet
