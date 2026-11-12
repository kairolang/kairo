// A generator yields a const place by copying it to a frame local (the
// promise's `T&` overload cannot bind a const lvalue, and its `T&&` takes no
// lvalue), so a const place of a move-only type cannot be yielded: SC182E,
// not clang's CL001E. A non-const place is yielded by address and a
// temporary by `T&&`; neither copies.

class Tok {
    pub var id: i32 = 0
    fn Tok(self) { self.id = 3 }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

class Holder {
    pub var t: Tok
    fn Holder(self) { self.t = Tok() }

    fn by_const(const self) -> yield Tok {
        yield self.t
    }

    fn by_self(self) -> yield Tok {
        yield self.t
        yield Tok()
    }
}

fn from_param(const h: Holder) -> yield Tok {
    yield h.t
}

fn main() -> i32 {
    var h = Holder()
    var s: i32 = 0
    for *v in h.by_self() {
        s += v->id
    }

    return s
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: yield_const_move_only.k:18:15: error [SC182E]: cannot copy a value of type 'Tok': it declares a move constructor and no copy constructor
// CHECK: yield_const_move_only.k:18:15: note [I900N]: 'self.t' is const, and a generator yields a const value by copying it
// CHECK: yield_const_move_only.k:28:11: error [SC182E]: cannot copy a value of type 'Tok'
// CHECK: yield_const_move_only.k:28:11: note [I900N]: 'h.t' is const, and a generator yields a const value by copying it
