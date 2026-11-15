// A call's result stored in a `bool` local and tested later splits the
// state as a test of the call does. This file pins the side that stays an
// error: the argument IS moved-from
//
//   1. on the branch the stored result says moved
//   2. between the call and the test (nothing is known yet)
//   3. after the test, when the stored result was used any other way first
//      (the link to the call is gone, so it counts as moved on both sides)
//   4. after the test, when both branches fall through to the use

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
fn moved_branch() -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    if ok {
        return t.n
// DIAG: cond_stored_negative.k:[[@LINE-1]]:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored_negative.k:[[@LINE-4]]:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_stored_negative.k:[[@LINE-54]]:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
    }

    return 0
}

fn moved_branch_negated() -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    if !ok {
        return 0
    }

    return t.n
// DIAG: cond_stored_negative.k:[[@LINE-1]]:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored_negative.k:[[@LINE-7]]:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_stored_negative.k:[[@LINE-71]]:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
}

// 2.
fn before_the_test() -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    var n  = t.n
// DIAG: cond_stored_negative.k:[[@LINE-1]]:14: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored_negative.k:[[@LINE-3]]:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_stored_negative.k:[[@LINE-82]]:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
    if ok {
        return 0
    }

    return n
}

// 3.
fn reassigned_first(c: bool) -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    ok = c
    if ok {
        return 0
    }

    return t.n
// DIAG: cond_stored_negative.k:[[@LINE-1]]:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored_negative.k:[[@LINE-8]]:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_stored_negative.k:[[@LINE-103]]:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
}

// 4.
fn falls_through() -> i32 {
    var q  = Queue()
    var t  = Task()
    var ok = q.push(&t)
    var n  = 0
    if ok {
        n = 1
    }

    return n + t.n
// DIAG: cond_stored_negative.k:[[@LINE-1]]:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_stored_negative.k:[[@LINE-8]]:14: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_stored_negative.k:[[@LINE-119]]:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
