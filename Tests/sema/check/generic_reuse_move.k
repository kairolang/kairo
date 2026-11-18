// A generic body that reads a `T` binding again after transferring it
// leaves the transfer a copy (one C++ template serves every instance, and
// the category is the instance's), and a pack expanded twice leaves the
// first expansion a copy. At an instance whose value cannot be copied that
// is a use after move: SC052E at the instance's use, with notes at the
// transfer and the read, rather than clang's deleted copy constructor. A
// COPY instance of the same body is fine.

class Mv {
    pub var n: i32 = 0
    fn Mv(self, n: i32) { self.n = n }
    @move fn Mv(self, other: Self) { self.n = other.n }
}

fn take(m: Mv) -> i32 { return m.n }
fn take_i(m: i32) -> i32 { return m }

fn <T> keep(x: T) -> T { var y = x; return x }
fn <...T> twice(...xs: T) -> i32 { return take(xs...) + take(xs...) }
fn <...T> twice_i(...xs: T) -> i32 { return take_i(xs...) + take_i(xs...) }

fn bad() -> i32 {
    var a = keep(Mv(1))
// DIAG: generic_reuse_move.k:[[@LINE-1]]:13: error [SC052E]: 'x' is used after being moved in 'keep<Mv>': 'Mv' cannot be copied, so the transfer moves it
    var b = twice(Mv(2))
// DIAG: generic_reuse_move.k:[[@LINE-1]]:13: error [SC052E]: 'xs' is used after being moved in 'twice<Mv>': 'Mv' cannot be copied, so the transfer moves it
    return a.n + b
}

fn good() -> i32 {
    var a = keep(3)                      // COPY: the copy is fine
    return a + twice_i(4)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
