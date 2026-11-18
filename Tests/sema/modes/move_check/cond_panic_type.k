// A part a function moves only on its way to a panic of one type is
// recorded with that type, and a typed catch arm receives it only when it
// catches that type: `catch e: Other` sees the argument whole after a call
// that moves it only when it panics with `Full`. A bare arm receives every
// part. A panic whose type is not known statically -- a rethrow of what a
// bare arm caught, a call into a function whose set is inferred -- counts
// for every arm.
//
//   1. moved on `Full`: the `Other` arm sees it whole, the `Full` arm moved
//   2. moved on `Other`: the reverse
//   3. a declared set
//   4. an inner arm that catches the type stops it: the outer bare arm
//      sees the part whole
//   5. a method receiver
//   6. an `@inout` parameter passed on: the type carries to the caller
//   7. the `try` expression form
//   8. fallbacks, every arm: a rethrow, a move before a call whose set is
//      not known

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

// Moves `v` only when it panics with `Full`.
fn on_full(@inout v: Task, bad: i32) panic {
    if bad == 1 {
        sink(v)
        panic Full {}
    }

    if bad == 2 {
        panic Other {}
    }
}

// Moves `v` only when it panics with `Other`.
fn on_other(@inout v: Task, bad: i32) panic {
    if bad == 1 {
        panic Full {}
    }

    if bad == 2 {
        sink(v)
        panic Other {}
    }
}

// Moves `v` only when it panics with `Full`.
fn declared(@inout v: Task, bad: i32) panic(Full, Other) {
    if bad == 1 {
        sink(v)
        panic Full {}
    }

    if bad == 2 {
        panic Other {}
    }
}

fn on_full_n(@inout v: Task, bad: i32) panic -> i32 {
    on_full(&v, bad)
    return 1
}

class Pool {
    pub var held: Task
    pub var full: bool = false
    fn Pool(self) { }

    // Moves its own `held` only when it panics with `Full`.
    fn spill(self, bad: i32) panic {
        if bad == 1 {
            sink(self.held)
            panic Full {}
        }

        if bad == 2 {
            panic Other {}
        }
    }
}

// 6. Moves `v` only when it panics with `Full`, as `on_full` does.
fn relay(@inout v: Task, bad: i32) panic {
    on_full(&v, bad)
}

fn boom(bad: i32) panic {
    if bad == 1 {
        panic Full {}
    }

    if bad == 2 {
        panic Other {}
    }
}

// 8. Moves `v` on whatever `boom` panics with.
fn rethrow(@inout v: Task, bad: i32) panic {
    try {
        boom(bad)
    } catch e {
        sink(v)
        panic e
    }
}

// 8. Moves `v` on whatever `boom` panics with.
fn before_call(@inout v: Task, bad: i32) panic {
    sink(v)
    boom(bad)
    v = Task()
}

// 1.
fn full_only() -> i32 {
    var t = Task()
    try {
        on_full(&t, 1)
    } catch e: Other {
        return t.n
    } catch e: Full {
        return t.n
    }

    return t.n
}

// 2.
fn other_only() -> i32 {
    var t = Task()
    try {
        on_other(&t, 2)
    } catch e: Full {
        return t.n
    } catch e: Other {
        return t.n
    }

    return t.n
}

// 3.
fn declared_set() -> i32 {
    var t = Task()
    try {
        declared(&t, 1)
    } catch e: Other {
        return t.n
    } catch e: Full {
        return t.n
    }

    return t.n
}

// 4.
fn stopped_inside() -> i32 {
    var t = Task()
    try {
        try {
            on_full(&t, 1)
        } catch e: Full {
            return 0
        }
    } catch {
        return t.n
    }

    return t.n
}

// 5.
fn receiver() -> i32 {
    var p = Pool()
    try {
        p.spill(1)
    } catch e: Other {
        return p.held.n
    } catch e: Full {
        return p.held.n
    }

    return p.held.n
}

// 6.
fn carried() -> i32 {
    var t = Task()
    try {
        relay(&t, 1)
    } catch e: Other {
        return t.n
    } catch e: Full {
        return t.n
    }

    return t.n
}

// 7.
fn expr_form() panic -> i32 {
    var t = Task()
    var n = try on_full_n(&t, 1) catch e: Other => t.n
    return n
}

// 8.
fn rethrown() -> i32 {
    var t = Task()
    try {
        rethrow(&t, 1)
    } catch e: Other {
        return t.n
    } catch e: Full {
        return 0
    }

    return t.n
}

fn unknown_set() -> i32 {
    var t = Task()
    try {
        before_call(&t, 1)
    } catch e: Other {
        return t.n
    } catch e: Full {
        return 0
    }

    return t.n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: cond_panic_type.k:141:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_panic_type.k:137:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'on_full', when it panics
// DIAG: cond_panic_type.k:45:14: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body panics
// DIAG: cond_panic_type.k:155:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_panic_type.k:151:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'on_other', when it panics
// DIAG: cond_panic_type.k:61:14: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body panics
// DIAG: cond_panic_type.k:169:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_panic_type.k:165:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'declared', when it panics
// DIAG: cond_panic_type.k:69:14: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body panics
// DIAG: cond_panic_type.k:199:16: error [SC052E]: 'p.held' is used after being moved
// DIAG: cond_panic_type.k:195:9: note [{{[A-Z0-9]+}}]: 'p.held' was moved here, by the call to 'spill', when it panics
// DIAG: cond_panic_type.k:91:18: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body panics
// DIAG: cond_panic_type.k:213:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_panic_type.k:209:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'relay', when it panics
// DIAG: cond_panic_type.k:103:5: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body panics
// DIAG: cond_panic_type.k:232:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_panic_type.k:230:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'rethrow', when it panics
// DIAG: cond_panic_type.k:121:14: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body panics
// DIAG: cond_panic_type.k:245:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_panic_type.k:243:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'before_call', when it panics
// DIAG: cond_panic_type.k:128:10: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body panics
