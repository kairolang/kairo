// A call through a local built from a closure literal takes the literal's
// defaults only while the local cannot hold another function. Once it is
// reassigned, its address is taken or a closure holds it by pointer, a
// short call is SC099E: the defaults belong to the literal, not to
// whatever the local holds when the call runs.

fn k(a: i32, b: i32) -> i32 {
    return a * 10 + b
}

fn set(p: *fn(i32, i32) -> i32) {
    *p = k
}

fn reassigned() -> i32 {
    var f = fn (a: i32, b: i32 = 5) -> i32 { return a + b }
    f = k
    return f(1)
}

fn reassigned_after() -> i32 {
    var f = fn (a: i32, b: i32 = 5) -> i32 { return a + b }
    var r = f(1)
    f = fn (a: i32, b: i32 = 7) -> i32 { return a * b }
    return r
}

fn typed_reassigned() -> i32 {
    var f: fn(i32, i32) -> i32 = fn (a: i32, b: i32 = 5) -> i32 { return a + b }
    if reassigned_after() > 0 {
        f = k
    }

    return f(1)
}

fn address_taken() -> i32 {
    var f = fn (a: i32, b: i32 = 5) -> i32 { return a + b }
    set(&f)
    return f(1)
}

fn captured_by_pointer() -> i32 {
    var f = fn (a: i32, b: i32 = 5) -> i32 { return a + b }
    var g = fn ()|*f| { *f = k }
    g()
    return f(1)
}

fn captured_all_by_pointer() -> i32 {
    var f = fn (a: i32, b: i32 = 5) -> i32 { return a + b }
    var g = fn ()|*| { *f = k }
    g()
    return f(1)
}

fn main() -> i32 {
    return reassigned() + typed_reassigned() + address_taken() + captured_by_pointer() + captured_all_by_pointer()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: closure_default_rebound.k:18:12: error [SC099E]: 'fn (i32, i32) -> i32' takes 2 argument(s), 1 given
// CHECK: closure_default_rebound.k:23:13: error [SC099E]: 'fn (i32, i32) -> i32' takes 2 argument(s), 1 given
// CHECK: closure_default_rebound.k:34:12: error [SC099E]: 'fn (i32, i32) -> i32' takes 2 argument(s), 1 given
// CHECK: closure_default_rebound.k:40:12: error [SC099E]: 'fn (i32, i32) -> i32' takes 2 argument(s), 1 given
// CHECK: closure_default_rebound.k:47:12: error [SC099E]: 'fn (i32, i32) -> i32' takes 2 argument(s), 1 given
// CHECK: closure_default_rebound.k:54:12: error [SC099E]: 'fn (i32, i32) -> i32' takes 2 argument(s), 1 given
