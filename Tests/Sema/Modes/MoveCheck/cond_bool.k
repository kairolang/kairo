// A `bool` function that moves a part of its argument only at `return
// true`, or only at `return false`, leaves it moved-from only on that
// outcome. A call that is the condition of an `if` or a loop, alone or
// under `!`, `&&` or `||`, marks the branch that outcome reaches; the
// other branch sees the argument whole. Anywhere else the call marks what
// any return leaves.
//
//   1. `if` / `if-else` / `else if`, both polarities
//   2. `while` and `while !...`: whole in the body, moved after the loop
//   3. `!`, `&&`, `||`
//   4. the value form `if c => a else b`
//   5. a stored result tested later, then the fallbacks: the result passed
//      on, a return of a non-literal bool, a part moved at both `return
//      true` and `return false`, the end of a `void` body
//   6. a method receiver (`self.held`), an `@inout` parameter passed on,
//      which carries the condition to its own caller, and a callee
//      defined after its caller

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

    // Moves `v` only when it returns false.
    fn refuse(self, @inout v: Task) -> bool {
        if self.full {
            self.held = v
            return false
        }

        return true
    }

    // Moves its own `held` only when it returns true.
    fn hand_off(self) -> bool {
        if self.full {
            return false
        }

        self.slot = self.held
        return true
    }

    // A non-literal return: either outcome.
    fn push_if(self, @inout v: Task, c: bool) -> bool {
        self.slot = v
        return c
    }

    // Moved at both returns.
    fn both(self, @inout v: Task) -> bool {
        self.slot = v
        if self.full {
            return false
        }

        return true
    }
}

fn read(t: *Task) -> i32 {
    return t->n
}

// 1.
fn if_true() -> i32 {
    var q = Queue()
    var t = Task()
    if q.push(&t) {
        return t.n
    }

    return t.n
}

fn if_else_false() -> i32 {
    var q = Queue()
    var t = Task()
    if q.refuse(&t) {
        return t.n
    } else {
        return t.n
    }
}

fn else_if_chain(c: bool) -> i32 {
    var q = Queue()
    var t = Task()
    if c {
        return 0
    } else if q.push(&t) {
        return 1
    } else if q.push(&t) {
        return t.n
    }

    return t.n
}

// 2.
fn wait_push() -> i32 {
    var q = Queue()
    var t = Task()
    while !q.push(&t) {
        var k = t.n
    }

    return t.n
}

fn while_true_body() -> i32 {
    var q = Queue()
    var t = Task()
    while q.push(&t) {
        t = Task()
    }

    return t.n
}

// 3.
fn and_both(c: bool) -> i32 {
    var q = Queue()
    var t = Task()
    if c && q.push(&t) {
        return t.n
    }

    return t.n
}

fn or_left() -> i32 {
    var q = Queue()
    var t = Task()
    if q.push(&t) || q.full {
        return 0
    }

    return t.n
}

fn not_push() -> i32 {
    var q = Queue()
    var t = Task()
    if !q.push(&t) {
        return t.n
    }

    return t.n
}

// 4.
fn value_form() -> i32 {
    var q = Queue()
    var t = Task()
    var n = if q.push(&t) => 0 else => t.n
    return n + t.n
}

// 5.
fn stored() -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    if ok {
        return 0
    }

    return t.n
}

fn pass_on(b: bool) -> bool {
    return b
}

fn passed() -> i32 {
    var q = Queue()
    var t = Task()
    if pass_on(q.push(&t)) {
        return 0
    }

    return t.n
}

fn non_literal() -> i32 {
    var q = Queue()
    var t = Task()
    if q.push_if(&t, true) {
        return 0
    }

    return t.n
}

fn both_outcomes() -> i32 {
    var q = Queue()
    var t = Task()
    if q.both(&t) {
        return 0
    }

    return t.n
}

// 6.
fn receiver() -> i32 {
    var q = Queue()
    if q.hand_off() {
        return q.held.n
    }

    return q.held.n
}

fn inout_param(@inout q: Queue, @inout t: Task) -> bool {
    if q.push(&t) {
        return true
    }

    return read(&t) == 0
}

fn later_caller() -> i32 {
    var t = Task()
    if push_later(&t) {
        return 0
    }

    return t.n
}

fn push_later(@inout v: Task) -> bool {
    var q = Queue()
    if q.full {
        return true
    }

    q.slot = v
    return false
}

// `inout_param` leaves its `t` moved-from only when it returns true.
fn carried() -> i32 {
    var q = Queue()
    var t = Task()
    if inout_param(&q, &t) {
        return t.n
    }

    return t.n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: cond_bool.k:89:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_bool.k:88:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_bool.k:39:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_bool.k:101:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_bool.k:98:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'refuse', when it returns false
// DIAG: cond_bool.k:46:25: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_bool.k:113:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_bool.k:112:15: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_bool.k:39:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_bool.k:127:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_bool.k:123:12: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_bool.k:39:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_bool.k:145:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_bool.k:144:13: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_bool.k:39:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_bool.k:168:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_bool.k:164:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_bool.k:39:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_bool.k:176:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_bool.k:175:16: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_bool.k:39:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_bool.k:202:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_bool.k:198:16: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_bool.k:39:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_bool.k:212:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_bool.k:208:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push_if', when it returns false
// DIAG: cond_bool.k:65:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_bool.k:222:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_bool.k:218:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'both', when it returns false
// DIAG: cond_bool.k:71:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_bool.k:229:16: error [SC052E]: 'q.held' is used after being moved
// DIAG: cond_bool.k:228:8: note [{{[A-Z0-9]+}}]: 'q.held' was moved here, by the call to 'hand_off', when it returns true
// DIAG: cond_bool.k:59:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_bool.k:249:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_bool.k:245:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push_later', when it returns false
// DIAG: cond_bool.k:258:14: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_bool.k:267:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_bool.k:266:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'inout_param', when it returns true
// DIAG: cond_bool.k:236:8: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
