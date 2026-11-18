// A function that may panic and moves a part of its argument only on the
// way to a panic, or only on the way to a return, leaves it moved-from
// only on that outcome. A move before a `panic` is recorded like a move
// before a `return`. The panic path of a call reaches the catch arms of
// the enclosing `try`, and the caller's own panic exit outside one; the
// path after the call is its return.
//
//   1. moved when it panics: the catch arm sees it moved, the code after
//      the call sees it whole
//   2. moved when it returns: the reverse
//   3. the `try` expression form
//   4. outside any `try`: the call's panic path is the caller's own panic,
//      which carries the move to the caller's caller
//   5. a typed arm passes other panics to the enclosing `try`
//   6. moved on both outcomes, a `bool` function that may panic, a method
//      receiver, a callee defined after its caller

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

// Moves `v` only when it panics.
fn give(@inout v: Task, bad: bool) panic {
    if bad {
        sink(v)
        panic Full {}
    }
}

// Moves `v` only when it returns.
fn take(@inout v: Task, bad: bool) panic {
    if bad {
        panic Full {}
    }

    sink(v)
}

fn take_n(@inout v: Task, bad: bool) panic -> i32 {
    if bad {
        panic Full {}
    }

    sink(v)
    return 1
}

// Moves `v` only when it panics with `Full`; may also panic with `Other`.
fn give2(@inout v: Task, bad: i32) panic {
    if bad == 1 {
        sink(v)
        panic Full {}
    }

    if bad == 2 {
        panic Other {}
    }
}

// Moved on both outcomes.
fn both(@inout v: Task, bad: bool) panic {
    sink(v)
    if bad {
        panic Full {}
    }
}

class Pool {
    pub var held: Task
    pub var slot: Task
    pub var full: bool = false
    fn Pool(self) { }

    // Moves its own `held` only when it panics.
    fn spill(self) panic {
        if self.full {
            sink(self.held)
            panic Full {}
        }
    }

    // Moves `v` only when it returns true.
    fn push(self, @inout v: Task) panic -> bool {
        if self.full {
            panic Full {}
        }

        if self.slot.n != 0 {
            return false
        }

        self.slot = v
        return true
    }
}

// 1.
fn on_panic() -> i32 {
    var t = Task()
    try {
        give(&t, true)
    } catch {
        return t.n
    }

    return t.n
}

// 2.
fn on_return() -> i32 {
    var t = Task()
    try {
        take(&t, true)
    } catch {
        return t.n
    }

    return t.n
}

// 3.
fn expr_form() -> i32 {
    var t = Task()
    var n = try take_n(&t, true) catch => t.n
    return n + t.n
}

// 4.
fn propagate(@inout v: Task) panic -> i32 {
    give(&v, true)
    return v.n
}

fn carried() -> i32 {
    var t = Task()
    try {
        propagate(&t)
    } catch {
        return t.n
    }

    return t.n
}

// 5.
fn typed_arm() -> i32 {
    var t = Task()
    try {
        try {
            give2(&t, 1)
        } catch e: Other {
            return 0
        }
    } catch {
        return t.n
    }

    return t.n
}

// 6.
fn both_outcomes() -> i32 {
    var t = Task()
    try {
        both(&t, true)
    } catch {
        return t.n
    }

    return t.n
}

fn bool_and_panic() -> i32 {
    var p = Pool()
    var t = Task()
    try {
        if p.push(&t) {
            return t.n
        }
    } catch {
        return t.n
    }

    return t.n
}

fn receiver() -> i32 {
    var p = Pool()
    try {
        p.spill()
    } catch {
        return p.held.n
    }

    return p.held.n
}

fn later_caller() -> i32 {
    var t = Task()
    try {
        give_later(&t)
    } catch {
        return t.n
    }

    return t.n
}

fn give_later(@inout v: Task) panic {
    sink(v)
    panic Full {}
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: cond_panic.k:121:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_panic.k:119:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'give', when it panics
// DIAG: cond_panic.k:43:14: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body panics
// DIAG: cond_panic.k:136:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_panic.k:131:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'take'
// DIAG: cond_panic.k:54:10: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_panic.k:143:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_panic.k:142:17: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'take_n'
// DIAG: cond_panic.k:62:10: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_panic.k:157:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_panic.k:155:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'propagate', when it panics
// DIAG: cond_panic.k:148:5: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body panics
// DIAG: cond_panic.k:173:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_panic.k:168:13: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'give2', when it panics
// DIAG: cond_panic.k:69:14: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body panics
// DIAG: cond_panic.k:185:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_panic.k:183:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'both', when it panics
// DIAG: cond_panic.k:80:10: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body panics
// DIAG: cond_panic.k:188:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_panic.k:183:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'both'
// DIAG: cond_panic.k:80:10: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_panic.k:196:20: error [SC052E]: 't' is used after being moved
// DIAG: cond_panic.k:195:12: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'push', when it returns true
// DIAG: cond_panic.k:110:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_panic.k:210:16: error [SC052E]: 'p.held' is used after being moved
// DIAG: cond_panic.k:208:9: note [{{[A-Z0-9]+}}]: 'p.held' was moved here, by the call to 'spill', when it panics
// DIAG: cond_panic.k:95:18: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body panics
// DIAG: cond_panic.k:221:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_panic.k:219:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'give_later', when it panics
// DIAG: cond_panic.k:228:10: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body panics
