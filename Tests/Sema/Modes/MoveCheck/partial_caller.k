// A function that returns with a part of storage it does not own still
// moved-from -- a field of `self`, of an `@inout` parameter, of what a
// parameter points at -- leaves that part moved-from in the caller's
// object. The caller's later use is the error; assigning the part again,
// in the function or in the caller, makes the object whole.
//
//   1. receiver: `h.take_a()` leaves `h.p.a` moved-from; a sibling field
//      stays usable; a second call reads all of `h`
//   2. a function that assigns the part again before it returns leaves
//      nothing
//   3. the callee is defined after its caller, moves on one path only, or
//      calls itself
//   4. `@inout` argument
//   5. pointer argument: `&h` and a pointer binding
//   6. receiver through a pointer
//   7. it carries: a function that passes its own `@inout` parameter to
//      such a function leaves the same part moved-from for its caller
//   8. a closure that leaves a by-pointer capture moved-from: the captured
//      binding is moved-from once the closure exists

class Str {
    pub var n: i32 = 0
    fn Str(self) { }
    fn Str(self, n: i32) { self.n = n }
    @move fn Str(self, other: Self) { self.n = other.n; other.n = 0 }
}

class Pair {
    pub var a: Str
    pub var b: Str
    fn Pair(self) { }
}

class Holder {
    pub var p: Pair
    fn Holder(self) { }
}

fn eat(s: Str) -> i32 { return s.n }

// 3. `take_later` is above `grab`, which it calls.
extend Holder {
    fn take_a(self) -> Str { return self.p.a }

    fn refill(self) -> Str {
        var a = self.p.a
        self.p.a = Str(1)
        return a
    }

    fn take_later(self) -> Str { return self.grab() }
    fn grab(self) -> Str { return self.p.b }

    fn maybe(self, c: bool) -> i32 {
        if c {
            return eat(self.p.a)
        }

        return 0
    }

    fn rec(self, n: i32) -> i32 {
        if n > 0 {
            return self.rec(n - 1)
        }

        return eat(self.p.a)
    }
}

fn drain(@inout h: Holder) -> Str { return h.p.a }
fn drain_ptr(p: *Holder) -> Str { return p->p.a }
fn pass_on(@inout h: Holder) -> Str { return h.take_a() }

// 1.
fn recv_reuse() -> i32 {
    var h = Holder()
    var a = h.take_a()
    return h.p.a.n
// DIAG: partial_caller.k:[[@LINE-1]]:12: error [SC052E]: 'h.p.a' is used after being moved
// DIAG: partial_caller.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'h.p.a' was moved here, by the call to 'take_a'
// DIAG: partial_caller.k:[[@LINE-39]]:37: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
}

fn recv_sibling() -> i32 {
    var h = Holder()
    var a = h.take_a()
    return h.p.b.n
}

fn recv_reassign() -> i32 {
    var h = Holder()
    var a = h.take_a()
    h.p.a = Str(2)
    return h.p.a.n
}

fn recv_twice() -> i32 {
    var h = Holder()
    var a = h.take_a()
    var b = h.take_a()
// DIAG: partial_caller.k:[[@LINE-1]]:13: error [SC052E]: 'h' is used after its part 'h.p.a' was moved
// DIAG: partial_caller.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'h.p.a' was moved here, by the call to 'take_a'
// DIAG: partial_caller.k:[[@LINE-61]]:37: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
    return a.n + b.n
}

// 2.
fn recv_refill() -> i32 {
    var h = Holder()
    var a = h.refill()
    var b = h.refill()
    return h.p.a.n
}

// 3.
fn recv_later() -> i32 {
    var h = Holder()
    var a = h.take_later()
    return h.p.b.n
// DIAG: partial_caller.k:[[@LINE-1]]:12: error [SC052E]: 'h.p.b' is used after being moved
// DIAG: partial_caller.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'h.p.b' was moved here, by the call to 'take_later'
// DIAG: partial_caller.k:[[@LINE-72]]:41: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
}

fn recv_maybe() -> i32 {
    var h = Holder()
    var n = h.maybe(false)
    return h.p.a.n
// DIAG: partial_caller.k:[[@LINE-1]]:12: error [SC052E]: 'h.p.a' is used after being moved
// DIAG: partial_caller.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'h.p.a' was moved here, by the call to 'maybe'
// DIAG: partial_caller.k:[[@LINE-76]]:24: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
}

fn recv_rec() -> i32 {
    var h = Holder()
    var n = h.rec(2)
    return h.p.a.n
// DIAG: partial_caller.k:[[@LINE-1]]:12: error [SC052E]: 'h.p.a' is used after being moved
// DIAG: partial_caller.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'h.p.a' was moved here, by the call to 'rec'
// DIAG: partial_caller.k:[[@LINE-74]]:20: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
}

// 4.
fn inout_reuse() -> i32 {
    var h = Holder()
    var a = drain(&h)
    return h.p.a.n
// DIAG: partial_caller.k:[[@LINE-1]]:12: error [SC052E]: 'h.p.a' is used after being moved
// DIAG: partial_caller.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'h.p.a' was moved here, by the call to 'drain'
// DIAG: partial_caller.k:[[@LINE-80]]:44: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
}

// 5.
fn ptr_addr() -> i32 {
    var h = Holder()
    var a = drain_ptr(&h)
    return h.p.a.n
// DIAG: partial_caller.k:[[@LINE-1]]:12: error [SC052E]: 'h.p.a' is used after being moved
// DIAG: partial_caller.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'h.p.a' was moved here, by the call to 'drain_ptr'
// DIAG: partial_caller.k:[[@LINE-89]]:42: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
}

fn ptr_binding(q: *Holder) -> i32 {
    var a = drain_ptr(q)
    return q->p.a.n
// DIAG: partial_caller.k:[[@LINE-1]]:12: error [SC052E]: 'q->p.a' is used after being moved
// DIAG: partial_caller.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'q->p.a' was moved here, by the call to 'drain_ptr'
// DIAG: partial_caller.k:[[@LINE-97]]:42: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
}

// 6.
fn recv_arrow(q: *Holder) -> i32 {
    var a = q->take_a()
    return q->p.a.n
// DIAG: partial_caller.k:[[@LINE-1]]:12: error [SC052E]: 'q->p.a' is used after being moved
// DIAG: partial_caller.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'q->p.a' was moved here, by the call to 'take_a'
// DIAG: partial_caller.k:[[@LINE-135]]:37: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
}

// 7.
fn carried() -> i32 {
    var h = Holder()
    var a = pass_on(&h)
    return h.p.a.n
// DIAG: partial_caller.k:[[@LINE-1]]:12: error [SC052E]: 'h.p.a' is used after being moved
// DIAG: partial_caller.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'h.p.a' was moved here, by the call to 'pass_on'
// DIAG: partial_caller.k:[[@LINE-115]]:46: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
}

// 8.
fn closure_capture() -> i32 {
    var h = Holder()
    var f = fn ()|*h| -> i32 { return eat(h->p.a) }
    return h.p.a.n
// DIAG: partial_caller.k:[[@LINE-1]]:12: error [SC052E]: 'h.p.a' is used after being moved
// DIAG: partial_caller.k:[[@LINE-3]]:13: note [{{[A-Z0-9]+}}]: 'h.p.a' was moved here, by the closure that captures it
// DIAG: partial_caller.k:[[@LINE-4]]:43: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
