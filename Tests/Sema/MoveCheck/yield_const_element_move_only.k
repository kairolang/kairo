// An element of a `[Tok]` field yielded from a `const self`
// generator is a const place: Sema binds the vector's `self` form of
// `op []`, but on a const receiver C++ calls the `const` overload, so the
// element is copied to a frame local, which a move-only type cannot be:
// SC182E. From a `self` generator it is yielded by address.

class Tok {
    pub var id: i32 = 0
    fn Tok(self) { self.id = 3 }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

class H {
    var vec: [Tok]
    fn H(self) { self.vec.push(Tok()) }
    fn by_const(const self) -> yield Tok { yield self.vec[0] }
    fn by_self(self) -> yield Tok { yield self.vec[0] }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: yield_const_element_move_only.k:16:50: error [SC182E]: cannot copy a value of type 'Tok': it declares a move constructor and no copy constructor
// CHECK: yield_const_element_move_only.k:16:50: note [I900N]: 'self.vec[0]' is const, and a generator yields a const value by copying it
