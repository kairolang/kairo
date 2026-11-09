// Inside a closure that captures `x` by pointer, `*x`
// is a place like any other. A check on it narrows it, a read of it needs
// one, and it starts Maybe: anything holding a pointer to `x` may write it
// while the closure waits, so it is also made Maybe by every call (as a
// global is) and by a write through a pointer the analysis cannot place.
// Each `bad_*` has one error, at the marked read; each `ok_*` none.

struct Node { pub var value: i32 = 1 }
struct Box  { pub var cache: Node? = null }

fn make() -> Node? { return Node() }
fn noop() { }

fn ok_checked() -> i32 {
    var x: Node? = make()
    var f = fn ()|*x| -> i32 {
        if (*x)? { return (*x).value }
        return 0
    }
    return f()
}

fn ok_operator() -> i32 {
    var n: i32? = 3
    var f = fn ()|*n| -> i32 {
        if (*n)? { return (*n) + 1 }
        return 0
    }
    return f()
}

fn ok_assigned() -> i32 {
    var x: Node? = null
    var f = fn ()|*x| -> i32 {
        *x = Node()
        return (*x).value
    }
    return f()
}

fn ok_all_ptr() -> i32 {
    var x: Node? = make()
    var f = fn ()|*| -> i32 {
        if (*x)? { return (*x).value }
        return 0
    }
    return f()
}

fn ok_field_path() -> i32 {
    var b = Box()
    var f = fn ()|*b| -> i32 {
        if (*b).cache? { return (*b).cache.value }
        return 0
    }
    return f()
}

fn bad_unchecked() -> i32 {
    var x: Node? = make()
    var f = fn ()|*x| -> i32 {
        return (*x).value     // BAD: starts Maybe
    }
    return f()
}

fn bad_call_after_check() -> i32 {
    var x: Node? = make()
    var f = fn ()|*x| -> i32 {
        if (*x)? {
            noop()
            return (*x).value // BAD: the call may change it
        }
        return 0
    }
    return f()
}

fn bad_assigned_null() -> i32 {
    var x: Node? = make()
    var f = fn ()|*x| -> i32 {
        *x = null
        return (*x).value     // BAD: always null
    }
    return f()
}

fn bad_write_through_copy() -> i32 {
    var x: Node? = make()
    var f = fn ()|*x| -> i32 {
        if (*x)? {
            var *p = x
            *p = null
            return (*x).value // BAD: written through a copy of the pointer
        }
        return 0
    }
    return f()
}

fn bad_loop() -> i32 {
    var x: Node? = make()
    var f = fn ()|*x| -> i32 {
        var s = 0
        if (*x)? {
            while s < 3 {
                s += (*x).value   // BAD: a loop drops what the head knew
                *x = null
            }
        }
        return s
    }
    return f()
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      capture_deref.k:62:17: error [SC265E]: '(*x)' may be null here; check it with 'if (*x)?' first
// DIAG-NEXT: capture_deref.k:60:5: note [I900N]: '(*x)' is reached through a pointer the closure captured: anything holding that pointer may change it, so it may be null on entry
// DIAG-NEXT: capture_deref.k:72:21: error [SC265E]: '(*x)' may be null here; check it with 'if (*x)?' first
// DIAG-NEXT: capture_deref.k:71:13: note [I900N]: '(*x)' is reached through a pointer the closure captured: this call may change it, which ends the check before it
// DIAG-NEXT: capture_deref.k:83:17: error [SC265E]: '(*x)' is always null here
// DIAG-NEXT: capture_deref.k:82:9: note [I900N]: '(*x)' is set to null here
// DIAG-NEXT: capture_deref.k:94:21: error [SC265E]: '(*x)' may be null here; check it with 'if (*x)?' first
// DIAG-NEXT: capture_deref.k:89:5: note [I900N]: '(*x)' is reached through a pointer the closure captured: anything holding that pointer may change it, so it may be null on entry
// DIAG-NEXT: capture_deref.k:107:23: error [SC265E]: '(*x)' may be null here; check it with 'if (*x)?' first
// DIAG-NEXT: capture_deref.k:102:5: note [I900N]: '(*x)' is reached through a pointer the closure captured: anything holding that pointer may change it, so it may be null on entry
// DIAG-NOT:  error
