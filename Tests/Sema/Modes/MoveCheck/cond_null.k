// A `T?` function that moves a part of its argument only at `return null`,
// or only where it returns a value that cannot be null, leaves it
// moved-from only on that outcome. A call tested against null directly --
// `f()?`, `f() == null`, `f() != null`, `null == f()`, under `!`, `&&` or
// `||` -- marks the branch that outcome reaches; the other branch sees the
// argument whole. Anywhere else the call marks what any return leaves.
//
//   1. `?` / `!...?`, both polarities, `if` and `if-else`
//   2. `== null`, `!= null`, `null == f()`
//   3. `&&`, `||`, `while`
//   4. a stored result tested later, then the fallbacks: a return of a
//      value that may be null, a part moved at both outcomes
//   5. a method receiver, an `@inout` parameter passed on, a callee
//      defined after its caller

class Task {
    pub var n: i32 = 0
    fn Task(self) { }
    @move fn Task(self, other: Self) {
        self.n = other.n
    }
}

class Table {
    pub var slot: Task
    pub var full: bool = false
    pub var held: Task
    fn Table(self) { }

    // Moves `v` only when it does not return null.
    fn put(self, @inout v: Task) -> i32? {
        if self.full {
            return null
        }

        self.slot = v
        return 1
    }

    // Moves `v` only when it returns null.
    fn reject(self, @inout v: Task) -> i32? {
        if self.full {
            self.held = v
            return null
        }

        return 2
    }

    // Moves its own `held` only when it does not return null.
    fn take_held(self) -> Task? {
        if self.full {
            return null
        }

        var t = self.held
        return t
    }

    // A value that may be null: either outcome.
    fn put_maybe(self, @inout v: Task, r: i32?) -> i32? {
        self.slot = v
        return r
    }

    // Moved at both outcomes.
    fn both(self, @inout v: Task) -> i32? {
        self.slot = v
        if self.full {
            return null
        }

        return 3
    }
}

// 1.
fn presence() -> i32 {
    var m = Table()
    var t = Task()
    if m.put(&t)? {
        return t.n
    }

    return t.n
}

fn absence_else() -> i32 {
    var m = Table()
    var t = Task()
    if !m.reject(&t)? {
        return t.n
    } else {
        return t.n
    }
}

// 2.
fn eq_null() -> i32 {
    var m = Table()
    var t = Task()
    if m.put(&t) == null {
        return t.n
    }

    return t.n
}

fn ne_null() -> i32 {
    var m = Table()
    var t = Task()
    if m.reject(&t) != null {
        return t.n
    }

    return t.n
}

fn null_first() -> i32 {
    var m = Table()
    var t = Task()
    if null == m.put(&t) {
        return 0
    }

    return t.n
}

// 3.
fn and_test(c: bool) -> i32 {
    var m = Table()
    var t = Task()
    if c && m.put(&t)? {
        return 0
    }

    return t.n
}

fn or_test() -> i32 {
    var m = Table()
    var t = Task()
    if m.put(&t) == null || m.full {
        return t.n
    }

    return 0
}

fn wait_put() -> i32 {
    var m = Table()
    var t = Task()
    while m.put(&t) == null {
        var k = t.n
    }

    return t.n
}

// 4.
fn stored() -> i32 {
    var m  = Table()
    var t  = Task()
    var r? = m.put(&t)
    if r? {
        return 0
    }

    return t.n
}

fn may_be_null() -> i32 {
    var m = Table()
    var t = Task()
    if m.put_maybe(&t, null)? {
        return 0
    }

    return t.n
}

fn both_outcomes() -> i32 {
    var m = Table()
    var t = Task()
    if m.both(&t)? {
        return 0
    }

    return t.n
}

// 5.
fn receiver() -> i32 {
    var m = Table()
    if m.take_held()? {
        return m.held.n
    }

    return m.held.n
}

fn inout_param(@inout m: Table, @inout t: Task) -> i32? {
    if m.reject(&t) == null {
        return null
    }

    return t.n
}

fn carried() -> i32 {
    var m = Table()
    var t = Task()
    if inout_param(&m, &t)? {
        return t.n
    }

    return t.n
}

fn later_caller() -> i32 {
    var t = Task()
    if find_later(&t) == null {
        return t.n
    }

    return t.n
}

fn find_later(@inout v: Task) -> Task? {
    var m = Table()
    if m.full {
        return null
    }

    var x = v
    return x
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: cond_null.k:82:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_null.k:81:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'put', when it does not return null
// DIAG: cond_null.k:36:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_null.k:92:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_null.k:91:9: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'reject', when it returns null
// DIAG: cond_null.k:43:25: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_null.k:106:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_null.k:102:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'put', when it does not return null
// DIAG: cond_null.k:36:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_null.k:116:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_null.k:112:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'reject', when it returns null
// DIAG: cond_null.k:43:25: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_null.k:126:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_null.k:122:16: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'put', when it does not return null
// DIAG: cond_null.k:36:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_null.k:144:16: error [SC052E]: 't' is used after being moved
// DIAG: cond_null.k:143:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'put', when it does not return null
// DIAG: cond_null.k:36:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_null.k:157:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_null.k:153:11: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'put', when it does not return null
// DIAG: cond_null.k:36:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_null.k:179:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_null.k:175:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'put_maybe', when it returns null
// DIAG: cond_null.k:62:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_null.k:189:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_null.k:185:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'both', when it returns null
// DIAG: cond_null.k:68:21: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_null.k:196:16: error [SC052E]: 'm.held' is used after being moved
// DIAG: cond_null.k:195:8: note [{{[A-Z0-9]+}}]: 'm.held' was moved here, by the call to 'take_held', when it does not return null
// DIAG: cond_null.k:56:17: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_null.k:217:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_null.k:213:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'inout_param', when it returns null
// DIAG: cond_null.k:203:8: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
// DIAG: cond_null.k:226:12: error [SC052E]: 't' is used after being moved
// DIAG: cond_null.k:222:8: note [{{[A-Z0-9]+}}]: 't' was moved here, by the call to 'find_later', when it does not return null
// DIAG: cond_null.k:235:13: note [{{[A-Z0-9]+}}]: it is moved here, and not assigned again before the body returns
