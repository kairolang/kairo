// In a `-> yield T` function with a MOVE `T`, `yield x` of a local or a
// by-value parameter moves it: the loop reading the generator takes the
// value. A later read is a use after move; assigning it again revives it.
// A field, a dereference or a const binding cannot be moved from and is
// never copied implicitly; a type with a public `copy()` is offered one.
// A temporary, a COPY value, a `-> yield *T` generator and a record's own
// `op in` are not moves.

class Str {
    pub var n: i32 = 0
    pub fn Str(self, n: i32) { self.n = n }
    @move pub fn Str(self, other: Self) { self.n = other.n; other.n = -1 }
    pub fn copy(const self) -> Str = Str(self.n)
}

class Mv {
    pub var n: i32 = 0
    pub fn Mv(self, n: i32) { self.n = n }
    @move pub fn Mv(self, other: Self) { self.n = other.n; other.n = -1 }
}

fn use(const s: Str) -> i32 = s.n

fn read_after(n: i32) -> yield Str {
    var s = Str(n)
    yield s
    use(s)
}

fn param_after(s: Str) -> yield Str {
    yield s
    use(s)
}

fn revived(n: i32) -> yield Str {
    var s = Str(0)
    for var i = 0; i < n; i++ {
        s = Str(i)
        yield s
    }
}

fn twice() -> yield Str {
    var s = Str(1)
    yield s
    s = Str(2)
    yield s
    use(s)
}

class Holder {
    pub var s: Str
    pub var m: Mv
    pub fn Holder(self) { self.s = Str(1); self.m = Mv(1) }

    pub fn field(self) -> yield Str {
        yield self.s
    }

    pub fn field_mv(self) -> yield Mv {
        yield self.m
    }

    pub fn op in (self) -> yield Str {
        yield self.s
    }
}

fn deref(p: *Str) -> yield Str {
    yield *p
}

fn constant() -> yield Str {
    const s = Str(1)
    yield s
}

fn temporary() -> yield Str {
    yield Str(3)
}

fn copies(n: i32) -> yield i32 {
    var k = n
    yield k
    yield k
}

fn pointer(p: *Str) -> yield *Str {
    yield p
    yield p
}

fn main() -> i32 = 0

/// A generic `yield x` moves at the instances that cannot copy `x`.
fn <T> twice(x: T) -> yield T {
    yield x
    var y = x
    yield y
}

fn instances() -> i32 {
    var s = 0
    for v in twice(Str(1)) {
        s += v.n
    }

    for k in twice(2) {
        s += k
    }

    return s
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT:  error
// CHECK:      :27:9: error [SC052E]: 's' is used after being moved
// CHECK-NEXT: :26:11: note [I900N]: 's' was moved here, out of the generator, to the loop reading it
// CHECK-NEXT: :26:12: note [I900N]: 's' has a 'copy' method: write 's.copy()' here if a copy was meant
// CHECK-NEXT: fix-it:"{{.*}}":{26:12-26:12}:".copy()"
// CHECK-NOT:  error
// CHECK:      :32:9: error [SC052E]: 's' is used after being moved
// CHECK-NEXT: :31:11: note [I900N]: 's' was moved here, out of the generator, to the loop reading it
// CHECK-NOT:  error
// CHECK:      :48:9: error [SC052E]: 's' is used after being moved
// CHECK-NEXT: :47:11: note [I900N]: 's' was moved here, out of the generator, to the loop reading it
// CHECK-NOT:  error
// CHECK:      :57:15: error [SC182E]: cannot copy a value of type 'Str': it declares a move constructor and no copy constructor
// CHECK-NEXT: :57:15: note [I900N]: a generator gives up the value it yields, and 'self.s' is not a local or a by-value parameter it can move from
// CHECK-NEXT: :57:21: note [I900N]: 'Str' has a 'copy' method: write 'self.s.copy()' for an explicit copy
// CHECK-NEXT: fix-it:"{{.*}}":{57:21-57:21}:".copy()"
// CHECK-NOT:  error
// CHECK:      :61:15: error [SC182E]: cannot copy a value of type 'Mv': it declares a move constructor and no copy constructor
// CHECK-NEXT: :61:15: note [I900N]: a generator gives up the value it yields, and 'self.m' is not a local or a by-value parameter it can move from
// CHECK-NOT:  fix-it
// CHECK-NOT:  error
// CHECK:      :70:11: error [SC182E]: cannot copy a value of type 'Str': it declares a move constructor and no copy constructor
// CHECK-NEXT: :70:11: note [I900N]: a generator gives up the value it yields, and '*p' is not a local or a by-value parameter it can move from
// CHECK-NEXT: :70:13: note [I900N]: 'Str' has a 'copy' method: write '(*p).copy()' for an explicit copy
// CHECK-NEXT: fix-it:"{{.*}}":{70:11-70:11}:"("
// CHECK-NEXT: fix-it:"{{.*}}":{70:13-70:13}:").copy()"
// CHECK-NOT:  error
// CHECK:      :75:11: error [SC182E]: cannot copy a value of type 'Str': it declares a move constructor and no copy constructor
// CHECK-NEXT: :75:11: note [I900N]: 's' is const, and a generator yields a const value by copying it
// CHECK-NEXT: :75:12: note [I900N]: 'Str' has a 'copy' method: write 's.copy()' for an explicit copy
// CHECK:      :104:14: error [SC052E]: 'x' is used after being moved in 'twice<Str>': 'Str' cannot be copied, so the transfer moves it
// CHECK-NEXT: :97:11: note [I900N]: 'x' was moved here, as a 'Str'
// CHECK-NOT:  error [
