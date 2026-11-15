// A local initialised from a call whose record moves a part only on some
// outcomes (`var ok = q.push(&t)`, `var r? = q.put(&t)`) holds that call's
// outcome: a later test of the local as a condition marks each branch as
// a test of the call would. Until it is tested the part is moved-from on
// every outcome. The link holds only while nothing else touches the
// local or the part; otherwise the part stays moved-from on both
// branches.
//
//   1. `bool`: `if ok`, `if !ok`, `const`, `||`, `while`
//   2. `T?`: `r == null`, `r != null`, `null == r`, `r?`
//   3. a method receiver, an `@inout` parameter, `return ok` / `return r`
//      carrying the outcome to the caller
//   4. a read of the part before the test is an error
//   5. what holds: a loop that does not touch either, a test repeated, a
//      local declared in a loop body
//   6. fallbacks, moved on both branches: the local reassigned, its
//      address taken, passed by `@inout`, read; the part reassigned and
//      moved again; a join whose sides disagree; a loop that assigns the
//      local

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
}

fn sink(t: Task) { }

fn flip(@inout b: bool) {
    b = !b
}

fn show(b: bool) { }

fn read(t: *Task) -> i32 {
    return t->n
}

// 1.
fn if_ok() -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    if ok {
        return t.n
    }

    return t.n
}

fn if_not_ok() -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    if !ok {
        return t.n
    }

    return t.n
}

fn const_ok() -> i32 {
    var   q  = Queue()
    var   t  = Task()
    const ok = q.push(&t)
    if ok {
        return 0
    }

    return t.n
}

fn or_ok(c: bool) -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    if ok || c {
        return 0
    }

    return t.n
}

fn while_not_ok() -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    var k  = 0
    while !ok && k < 3 {
        k += t.n
    }

    return t.n
}

// 2.
fn r_eq_null() -> i32 {
    var q  = Queue()
    var t  = Task()
    var r? = q.put(&t)
    if r == null {
        return t.n
    }

    return t.n
}

fn r_ne_null() -> i32 {
    var q  = Queue()
    var t  = Task()
    var r? = q.put(&t)
    if r != null {
        return 0
    }

    return t.n
}

fn null_eq_r() -> i32 {
    var q  = Queue()
    var t  = Task()
    var r? = q.put(&t)
    if null == r {
        return t.n
    }

    return 0
}

fn r_present() -> i32 {
    var q  = Queue()
    var t  = Task()
    var r? = q.put(&t)
    if r? {
        return t.n
    }

    return t.n
}

// 3.
fn receiver() -> i32 {
    var q  = Queue()
    var ok = q.hand_off()
    if !ok {
        return q.held.n
    }

    return q.held.n
}

fn inout_param(@inout q: Queue, @inout t: Task) -> i32 {
    var ok = q.push(&t)
    if ok {
        return 0
    }

    return read(&t)
}

// Moves `v` only when it returns true.
fn return_ok(@inout q: Queue, @inout v: Task) -> bool {
    var ok = q.push(&v)
    return ok
}

// Moves `v` only when it does not return null.
fn return_r(@inout q: Queue, @inout v: Task) -> i32? {
    var r? = q.put(&v)
    return r
}

fn carried() -> i32 {
    var q = Queue()
    var t = Task()
    if !return_ok(&q, &t) {
        return t.n
    }

    return t.n
}

fn carried_null() -> i32 {
    var q = Queue()
    var t = Task()
    if return_r(&q, &t) == null {
        return t.n
    }

    return t.n
}

// 4.
fn read_before() -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    var k  = t.n
    if ok {
        return 0
    }

    return k
}

// 5.
fn loop_untouched(c: bool) -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    var k  = 0
    while c && k < 3 {
        k += 1
    }

    if ok {
        return 0
    }

    return t.n
}

fn tested_twice() -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    var k  = 0
    if ok {
        k = 1
    }

    if !ok {
        return t.n
    }

    return t.n
}

fn declared_in_loop(c: bool) -> i32 {
    var q = Queue()
    var t = Task()
    while c {
        var ok = q.push(&t)
        if !ok {
            return t.n
        }

        t = Task()
    }

    return 0
}

// 6.
fn reassigned_local() -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    ok = q.full
    if ok {
        return 0
    }

    return t.n
}

fn address_taken() -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    var *p = &ok
    if ok {
        return 0
    }

    return t.n
}

fn passed_inout() -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    flip(&ok)
    if ok {
        return 0
    }

    return t.n
}

fn read_local() -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    show(ok)
    if ok {
        return 0
    }

    return t.n
}

fn part_moved_again() -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    t = Task()
    sink(t)
    if !ok {
        return t.n
    }

    return 0
}

fn join_disagrees(c: bool) -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    if c {
        ok = false
    }

    if ok {
        return 0
    }

    return t.n
}

fn join_part_moved(c: bool) -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    if c {
        t = Task()
        sink(t)
    }

    if !ok {
        return t.n
    }

    return 0
}

fn loop_assigns(c: bool) -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    while c {
        ok = q.full
    }

    if ok {
        return 0
    }

    return t.n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: cond_stored.k:84:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored.k:82:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_stored.k:41:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_stored.k:98:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored.k:93:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_stored.k:41:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_stored.k:132:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored.k:126:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_stored.k:41:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_stored.k:144:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored.k:139:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'put', when it does not return null
// DIAG: cond_stored.k:51:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_stored.k:174:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored.k:172:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'put', when it does not return null
// DIAG: cond_stored.k:51:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_stored.k:188:12: error [SC052E]: 'q.held' is used after being moved
// DIAG: cond_stored.k:183:14: note [{{[A-Z0-9]+}}]: 'q.held' was moved here, by the call to 'hand_off', when it returns true
// DIAG: cond_stored.k:61:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_stored.k:219:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored.k:215:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'return_ok', when it returns true
// DIAG: cond_stored.k:202:14: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_stored.k:229:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored.k:225:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'return_r', when it does not return null
// DIAG: cond_stored.k:208:14: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_stored.k:237:14: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored.k:236:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_stored.k:41:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_stored.k:275:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored.k:265:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_stored.k:41:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_stored.k:303:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored.k:297:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_stored.k:41:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_stored.k:315:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored.k:309:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_stored.k:41:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_stored.k:327:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored.k:321:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_stored.k:41:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_stored.k:339:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored.k:333:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_stored.k:41:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_stored.k:349:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored.k:347:10: note [{{[A-Z0-9]+}}]: 't' was moved here, into a by-value parameter
// DIAG: cond_stored.k:367:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored.k:358:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_stored.k:41:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_stored.k:380:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored.k:376:14: note [{{[A-Z0-9]+}}]: 't' was moved here, into a by-value parameter
// DIAG: cond_stored.k:398:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored.k:389:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_stored.k:41:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
