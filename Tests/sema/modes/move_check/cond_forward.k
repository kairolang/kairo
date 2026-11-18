// A function that returns a call's result as its own moves what the
// callee moves on the outcome it returns, and its record says so: a
// caller that tests it marks only the branch that outcome reaches. The
// forwarded value is, in a `bool` function, a condition that splits on a
// call (the call, `!`, parentheses, `&&`, `||`, `f()?`, `f() == null`),
// and in a `T?` function a call of the same `T?` type; an expression body
// forwards as its `return` does.
//
//   1. `return q.push(&v)`: moved when it returns true, both polarities
//   2. `!`, parentheses and `&&` around the call
//   3. an expression body, bool and `T?`
//   4. `T?`: moved when it does not return null, both polarities
//   5. a method receiver (`self.held`), and a part of the caller's own
//      storage passed on (`self.t`)
//   6. a forwarder of a forwarder
//   7. fallback: the result passed through another call first

class Task {
    pub var n: i32 = 0
    fn Task(self) { }
    @move fn Task(self, other: Self) {
        self.n = other.n
    }
}

class Queue {
    pub var slot: Task
    pub var full: bool = false
    pub var held: Task
    fn Queue(self) { }

    // Moves `v` only when it returns true.
    fn push(self, @inout v: Task) -> bool {
        if self.full {
            return false
        }

        self.slot = v
        return true
    }

    // Moves `v` only when it does not return null.
    fn put(self, @inout v: Task) -> i32? {
        if self.full {
            return null
        }

        self.slot = v
        return 1
    }

    // Moves its own `held` only when it returns true.
    fn hand_off(self) -> bool {
        if self.full {
            return false
        }

        self.slot = self.held
        return true
    }

    // 5. Forwards `hand_off`: moves `self.held` only when it returns true.
    fn relay(self) -> bool {
        return self.hand_off()
    }
}

class Pair {
    pub var t: Task
    pub var q: Queue
    fn Pair(self) { }

    // 5. Moves its own `t` only when it returns true.
    fn stash(self) -> bool {
        return self.q.push(&self.t)
    }
}

fn try_push(@inout q: Queue, @inout v: Task) -> bool {
    return q.push(&v)
}

fn not_push(@inout q: Queue, @inout v: Task) -> bool {
    return !(q.push(&v))
}

fn and_push(@inout q: Queue, @inout v: Task, c: bool) -> bool {
    return c && q.push(&v)
}

fn push_expr(@inout q: Queue, @inout v: Task) -> bool = q.push(&v)

fn find(@inout q: Queue, @inout v: Task) -> i32? {
    return q.put(&v)
}

fn find_expr(@inout q: Queue, @inout v: Task) -> i32? = q.put(&v)

fn relay2(@inout q: Queue, @inout v: Task) -> bool {
    return try_push(&q, &v)
}

fn pass_on(b: bool) -> bool {
    return b
}

fn passed(@inout q: Queue, @inout v: Task) -> bool {
    return pass_on(q.push(&v))
}

// 1.
fn on_true() -> i32 {
    var q = Queue()
    var t = Task()
    if try_push(&q, &t) {
        return t.n
    }

    return t.n
}

fn on_false() -> i32 {
    var q = Queue()
    var t = Task()
    if !try_push(&q, &t) {
        return t.n
    }

    return t.n
}

// 2.
fn negated() -> i32 {
    var q = Queue()
    var t = Task()
    if not_push(&q, &t) {
        return t.n
    }

    return t.n
}

fn anded() -> i32 {
    var q = Queue()
    var t = Task()
    if !and_push(&q, &t, true) {
        return t.n
    }

    return t.n
}

// 3.
fn expr_body() -> i32 {
    var q = Queue()
    var t = Task()
    if push_expr(&q, &t) {
        return t.n
    }

    return t.n
}

fn expr_body_null() -> i32 {
    var q = Queue()
    var t = Task()
    if find_expr(&q, &t) != null {
        return t.n
    }

    return t.n
}

// 4.
fn null_eq() -> i32 {
    var q = Queue()
    var t = Task()
    if find(&q, &t) == null {
        return t.n
    }

    return t.n
}

// 5.
fn receiver() -> i32 {
    var q = Queue()
    if !q.relay() {
        return q.held.n
    }

    return q.held.n
}

fn own_part() -> i32 {
    var p = Pair()
    if p.stash() {
        return p.t.n
    }

    return p.t.n
}

// 6.
fn two_levels() -> i32 {
    var q = Queue()
    var t = Task()
    if relay2(&q, &t) {
        return t.n
    }

    return t.n
}

// 7.
fn fallback() -> i32 {
    var q = Queue()
    var t = Task()
    if passed(&q, &t) {
        return 0
    }

    return t.n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: cond_forward.k:116:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_forward.k:115:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'try_push', when it returns true
// DIAG: cond_forward.k:80:12: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_forward.k:129:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_forward.k:125:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'try_push', when it returns true
// DIAG: cond_forward.k:80:12: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_forward.k:140:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_forward.k:136:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'not_push', when it returns false
// DIAG: cond_forward.k:84:14: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_forward.k:150:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_forward.k:146:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'and_push', when it returns true
// DIAG: cond_forward.k:88:17: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_forward.k:158:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_forward.k:157:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push_expr', when it returns true
// DIAG: cond_forward.k:91:57: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_forward.k:168:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_forward.k:167:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'find_expr', when it does not return null
// DIAG: cond_forward.k:97:57: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_forward.k:182:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_forward.k:178:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'find', when it does not return null
// DIAG: cond_forward.k:94:12: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_forward.k:192:12: error [SC052E]: 'q.held' is used after being moved
// DIAG: cond_forward.k:188:9: note [{{[A-Z0-9]+}}]: 'q.held' was moved here, by the call to 'relay', when it returns true
// DIAG: cond_forward.k:64:16: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_forward.k:198:16: error [SC052E]: 'p.t' is used after being moved
// DIAG: cond_forward.k:197:8: note [{{[A-Z0-9]+}}]: 'p.t' was moved here, by the call to 'stash', when it returns true
// DIAG: cond_forward.k:75:16: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_forward.k:209:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_forward.k:208:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'relay2', when it returns true
// DIAG: cond_forward.k:100:12: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_forward.k:223:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_forward.k:219:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'passed', when it returns false
// DIAG: cond_forward.k:108:20: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
