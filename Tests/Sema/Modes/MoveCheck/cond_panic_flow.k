// The panic path of a call, past the cases of cond_panic.k:
//
//   1. a panic that passes a typed arm leaves each block once: the
//      `finally` of the `try` body runs once on that path, so its move is
//      not seen twice
//   2. a user operator marked `panic` is a point where the `try` body can
//      reach its catch arms, after a call that is one too
//   3. a closure that is not marked `panic` has no panic exit: a call in
//      it does not record what is moved-from at that point

class Task {
    pub var n: i32 = 0
    fn Task(self) { }
    @move fn Task(self, other: Self) {
        self.n = other.n
    }
}

struct Full {
    fn op panic (const self) -> string {
        return "full"
    }
}

struct Other {
    fn op panic (const self) -> string {
        return "other"
    }
}

fn sink(t: Task) { }

fn boom(b: bool) panic {
    if b {
        panic Full {}
    }

    if !b {
        panic Other {}
    }
}

class Num {
    pub var v: i32 = 0
    fn Num(self) { }

    fn op - (const self) panic -> Num {
        if self.v == 0 {
            panic Full {}
        }

        return Num()
    }
}

// 1.
fn fin(b: bool) panic -> i32 {
    var x = Task()
    try {
        finally {
            sink(x)
        }

        boom(b)
    } catch e: Other {
        return 0
    }

    return 1
}

// 2.
fn unop() -> i32 {
    var t = Task()
    var x = Num()
    try {
        boom(false)
        sink(t)
        var y = -x
    } catch {
        return t.n
    }

    return 0
}

class Holder {
    pub var a: Task
    fn Holder(self) { }
}

// 3.
fn clo() -> i32 {
    var h = Holder()
    var f = fn ()|*h| {
        var k = h->a
        var g = fn () -> i32 { return 1 }
        var z = g()
        h->a = Task()
    }

    return h.a.n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: cond_panic_flow.k:81:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_panic_flow.k:78:14: note [{{[A-Z0-9]+}}]: 't' was moved here, into a by-value parameter
