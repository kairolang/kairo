// A generic operand bound ahead of a later argument that has an effect is
// a snapshot at an instance whose type copies, and a borrow at an instance
// whose type cannot be copied: a move-only instance is read in place, with
// no copy and no move, and sees what the later argument wrote through the
// same pointer.

var moves: i32 = 0

interface Counter {
    fn get(const self) -> i32
    fn bump(self) -> i32
}

class Mv impl Counter {
    pub var n: i32 = 0

    pub fn Mv(self, n: i32) {
        self.n = n
    }

    @move
    pub fn Mv(self, other: Self) {
        self.n  = other.n
        other.n = -1
        moves += 1
    }

    pub fn get(const self) -> i32 = self.n

    pub fn bump(self) -> i32 {
        self.n += 1
        return self.n
    }

    pub fn op == (const self, const o: Mv) -> bool = self.n == o.n
}

class Cp impl Counter {
    pub var n: i32 = 0

    pub fn Cp(self, n: i32) {
        self.n = n
    }

    pub fn get(const self) -> i32 = self.n

    pub fn bump(self) -> i32 {
        self.n += 1
        return self.n
    }

    pub fn op == (const self, const o: Cp) -> bool = self.n == o.n
}

class <T> Box {
    pub var v: T
    pub fn Box(self, v: T) {
        self.v = v
    }
}

fn <T impl Counter> read(const s: T, at: i32) -> i32 = s.get() * 100 + at

fn <T impl Counter> through_ptr(p: *T) -> i32 {
    return read(*p, p->bump())
}

fn <T impl Counter> through_field(b: *Box<T>) -> i32 {
    return read(b->v, b->v.bump())
}

fn main() -> i32 {
    var m = Mv(4)
    moves = 0
    if through_ptr(&m) != 505 {
        return 1
    }

    var bm = Box<Mv>(Mv(4))
    moves = 0
    if through_field(&bm) != 505 {
        return 2
    }

    if moves != 0 {
        return 4
    }

    // A copyable instance keeps the snapshot taken before the bump.
    var c = Cp(4)
    if through_ptr(&c) != 405 || c.n != 5 {
        return 5
    }

    var bc = Box<Cp>(Cp(4))
    if through_field(&bc) != 405 || bc.v.n != 5 {
        return 6
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s
// CHECK-NOT:   error [
// CHECK-LABEL: through_ptr(T * p) noexcept {
// CHECK:       ::__kairo_bind_t<T> __kairo_ord{{[0-9]+}} =((* p));
// CHECK-LABEL: through_field(
// CHECK:       ::__kairo_bind_t<T> __kairo_ord{{[0-9]+}} =(b->v);

// REQUIRES: clang
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d %t.o2
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2
// RUN: %t.o2.exe
