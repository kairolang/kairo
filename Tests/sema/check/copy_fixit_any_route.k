// A use after move, and a copy that cannot be made of a place, offer an
// explicit `.copy()` when `.copy()` on the type calls a public
// `fn copy(const self) -> Self`: declared in the class, or in an `extend`
// of it whose bounds the type meets. An extension whose bound the type does
// not meet offers nothing. A local left operand of a derived `op +` at its
// last use moves into the result, and a plain loop binder of such a type
// borrows its element: neither copies, so neither is an error.

interface Dup {
    fn dup(const self) -> i32
}

class A {
    pub fn A(self) { }
}

class B {
    pub fn B(self) { }
}

extend A impl Dup {
    fn dup(const self) -> i32 = 1
}

class Str {
    pub var n: i32 = 0
    pub fn Str(self, n: i32) { self.n = n }
    @move pub fn Str(self, other: Self) { self.n = other.n; other.n = -1 }
    pub fn op += (self, const o: Str) { self.n += o.n }
}

extend Str {
    pub fn copy(const self) -> Str = Str(self.n)
}

class <T> Box {
    pub var v: T
    pub var k: i32 = 0
    pub fn Box(self, v: T) { self.v = v }
    @move pub fn Box(self, other: Self) { self.v = other.v; self.k = other.k }
}

extend <T impl Dup> Box<T> {
    pub fn copy(const self) -> Self = Box<T>(self.v)
}

class Pair {
    pub var s: Str
    pub var t: Str
    pub fn Pair(self) { self.s = Str(1); self.t = Str(2) }
}

class Shelf {
    pub var a: Str
    pub fn Shelf(self) { self.a = Str(1) }
    pub fn op in (self) -> yield *Str { yield &self.a }
}

fn take(s: Str) -> i32 = s.n
fn <T> take_box(b: Box<T>) -> i32 = b.k
fn read(const s: Str) -> i32 = s.n
fn read_pair(const p: Pair) -> i32 = p.s.n

fn moved_arg() -> i32 {
    var s = Str(1)
    take(s)
    return read(s)
}

fn moved_into_var() -> i32 {
    var s = Str(1)
    var t = s
    return read(s) + t.n
}

fn moved_part() -> i32 {
    var p = Pair()
    take(p.s)
    return read_pair(p)
}

fn moved_through_pointer(p: *Pair) -> i32 {
    take(cxx::std::move(p->s))
    return read(p->s)
}

fn box_meets() -> i32 {
    var b = Box<A>(A())
    take_box(b)
    return b.k
}

fn box_fails() -> i32 {
    var b = Box<B>(B())
    take_box(b)
    return b.k
}

fn const_into_param() -> i32 {
    const s = Str(1)
    return take(s)
}

fn derived_plus() -> i32 {
    var s = Str(1)
    var t = s + Str(2)
    return t.n
}

fn binder() -> i32 {
    var shelf = Shelf()
    var n = 0
    for x in shelf {
        n += x.n
    }

    return n
}

fn main() -> i32 = 0

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT:  error
// CHECK:      :67:17: error [SC052E]: 's' is used after being moved
// CHECK-NEXT: :66:10: note [I900N]: 's' was moved here, into a by-value parameter
// CHECK-NEXT: :66:11: note [I900N]: 's' has a 'copy' method: write 's.copy()' here if a copy was meant
// CHECK-NEXT: fix-it:"{{.*}}":{66:11-66:11}:".copy()"
// CHECK-NOT:  error
// CHECK:      :73:17: error [SC052E]: 's' is used after being moved
// CHECK:      fix-it:"{{.*}}":{72:14-72:14}:".copy()"
// CHECK-NOT:  error
// CHECK:      :79:22: error [SC052E]: 'p' is used after its part 'p.s' was moved
// CHECK:      fix-it:"{{.*}}":{78:13-78:13}:".copy()"
// CHECK-NOT:  error
// CHECK:      :84:17: error [SC052E]: 'p->s' is used after being moved
// CHECK:      fix-it:"{{.*}}":{83:29-83:29}:".copy()"
// CHECK-NOT:  error
// CHECK:      :90:12: error [SC052E]: 'b' is used after being moved
// CHECK:      fix-it:"{{.*}}":{89:15-89:15}:".copy()"
// CHECK-NOT:  error
// CHECK:      :96:12: error [SC052E]: 'b' is used after being moved
// CHECK-NOT:  fix-it
// CHECK-NOT:  error
// CHECK:      :101:17: error [SC182E]: cannot copy a value of type 'Str': it declares a move constructor and no copy constructor
// CHECK-NEXT: :101:17: note [I900N]: 's' is const, so the transfer into a by-value parameter cannot move it, and moving is the only transfer its type has
// CHECK-NEXT: :101:18: note [I900N]: 'Str' has a 'copy' method: write 's.copy()' for an explicit copy
// CHECK-NEXT: fix-it:"{{.*}}":{101:18-101:18}:".copy()"
// CHECK-NOT:  error
// CHECK-NOT:  error [
ffi "c++" import "utility"
