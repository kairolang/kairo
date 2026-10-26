// G17 (Compiler/Sema/NULLABLE.md 3.7): the analysis follows aliases. A
// pointer value (`var p = &x`) or a closure capturing by non-const pointer
// (`|*x|`) CARRIES the places it can write; calling it or writing through
// it weakens them; once it escapes (passed to a parameter, stored in a
// field), every later call does, while a check with no call after it still
// narrows. Each `bad_*` has one error, at the marked read; each `ok_*`
// none. Covered:
//   - NULLABLE.md 3.7's own example: `clear()` may null `x`;
//   - `var p = &x; *p = null`, and through a copy `var q = p`;
//   - a pointer that does not escape: calls leave `x` proven;
//   - escape to a parameter, and a store into a field: every later call;
//   - a closure passed on: every later call;
//   - a copy of a closure carries what it does;
//   - a `const *` capture or a closure passed one: nothing;
//   - by-copy captures: inside the closure, the state where it was made
//     (`a + 0` proven), less what the closure assigns its copy;
//   - inside a `|*x|` closure, `x` is the pointer: `*x = null` and
//     `*count += 1` type-check;
//   - a pointer that escapes inside a loop body: on the next pass a call
//     before the escape may write `x`, so `x` is not proven at the head;
//   - a nullable reached through a subscript or `->` is no place: the
//     error says why and suggests a local copy.

class Node { pub var value: i32 = 1 }
struct Holder { pub var p: (*(i32?))? = null }
struct S { pub var cache: Node? = null }

fn make() -> Node? { return Node() }
fn noop() { }
fn keep(p: *(i32?)) { }
fn stash(f: fn()) { }

fn bad_spec_example() -> i32 {
    var x: Node? = make()
    var clear = fn ()|*x| { *x = null }
    if x? {
        clear()
        return x.value
    }
    return 0
}

fn ok_spec_no_call_of_it() -> i32 {
    var x: Node? = make()
    var clear = fn ()|*x| { *x = null }
    if x? {
        noop()
        return x.value
    }
    return 0
}

fn bad_write_through() -> i32 {
    var x: i32? = 1
    var *p = &x
    *p = null
    return x + 0
}

fn bad_write_through_copy() -> i32 {
    var x: i32? = 1
    var *p = &x
    var *q = p
    *q = null
    return x + 0
}

fn ok_not_escaped() -> i32 {
    var x: i32? = 1
    var *p = &x
    noop()
    var a? = *p
    return x + 0
}

fn bad_escape_to_parameter() -> i32 {
    var x: i32? = 1
    var *p = &x
    keep(p)
    if x? {
        var a = x + 0
        noop()
        return x + a
    }
    return 0
}

fn bad_store_into_field() -> i32 {
    var x: i32? = 1
    var *p = &x
    var h = Holder()
    h.p = p
    if x? {
        noop()
        return x + 0
    }
    return 0
}

fn bad_closure_escapes() -> i32 {
    var x: i32? = 1
    var clear = fn ()|*x| { *x = null }
    stash(clear)
    if x? {
        noop()
        return x + 0
    }
    return 0
}

fn bad_closure_copy() -> i32 {
    var x: i32? = 1
    var clear = fn ()|*x| { *x = null }
    var again = clear
    again()
    return x + 0
}

fn ok_const_capture() -> i32 {
    var x: i32? = 1
    var look = fn ()|const *x| -> i32 { return 0 }
    look()
    stash(fn ()|const *x| { })
    noop()
    return x + 0
}

fn ok_by_copy(a: i32?) -> i32 {
    if a? {
        var f = fn () -> i32 { return a + 0 }
        return f()
    }
    return 0
}

fn bad_by_copy_assigned(a: i32?) -> i32 {
    if a? {
        var f = fn () -> i32 { var r = a + 0; a = null; return r }
        return f()
    }
    return 0
}

fn ok_pointer_capture_typed() -> i32 {
    var count = 0
    var inc = fn ()|*count| { *count += 1 }
    var all = fn ()|*| { *count += 1 }
    inc()
    all()
    return count
}

fn bad_escape_in_loop(n: i32) -> i32 {
    var x: i32? = 1
    var r = 0
    while r < n {
        noop()
        r += x
        keep(&x)
        x = 2
    }
    return r
}

fn bad_through_subscript(const xs: [S; 2]) -> i32 {
    if xs[0].cache? { return xs[0].cache.value }
    return 0
}

fn bad_through_arrow(p: *S) -> i32 {
    if p->cache? { return p->cache.value }
    return 0
}

fn ok_local_copy(p: *S) -> i32 {
    var c? = p->cache
    if c? { return c.value }
    return 0
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG: alias.k:38:16: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: alias.k:37:9: note [{{.*}}]: this call runs a closure that holds a pointer to 'x', so it may change 'x'
// DIAG-NOT: {{error|warning}}
// DIAG: alias.k:57:12: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: alias.k:56:5: note [{{.*}}]: 'x' may be changed here, through a pointer to it
// DIAG-NOT: {{error|warning}}
// DIAG: alias.k:65:12: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: alias.k:64:5: note [{{.*}}]: 'x' may be changed here, through a pointer to it
// DIAG-NOT: {{error|warning}}
// DIAG: alias.k:83:16: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: alias.k:79:10: note [{{.*}}]: a pointer to 'x' escapes here; any call after it, or a write through it, may change 'x'
// DIAG-NOT: {{error|warning}}
// DIAG: alias.k:95:16: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: alias.k:92:11: note [{{.*}}]: a pointer to 'x' escapes here; any call after it, or a write through it, may change 'x'
// DIAG-NOT: {{error|warning}}
// DIAG: alias.k:106:16: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: alias.k:103:11: note [{{.*}}]: a pointer to 'x' escapes here; any call after it, or a write through it, may change 'x'
// DIAG-NOT: {{error|warning}}
// DIAG: alias.k:116:12: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: alias.k:115:5: note [{{.*}}]: this call runs a closure that holds a pointer to 'x', so it may change 'x'
// DIAG-NOT: {{error|warning}}
// DIAG: alias.k:138:40: error [SC001E]: 'a' may be null here; check it with 'if a?' first
// DIAG-NEXT: alias.k:136:25: note [{{.*}}]: 'a' is captured by the closure: inside it, 'a' is as it was where the closure was made, less what the closure assigns it
// DIAG-NOT: {{error|warning}}
// DIAG: alias.k:158:14: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: alias.k:159:14: note [{{.*}}]: 'x' may be changed in the loop here, so it may be null at the top of the loop
// DIAG-NOT: {{error|warning}}
// DIAG: alias.k:166:30: error [SC001E]: 'xs[0].cache' is nullable and no check narrows it: it goes through a subscript, which a null check does not follow; copy it to a local ('var c = xs[0].cache') and check that
// DIAG-NOT: {{error|warning}}
// DIAG: alias.k:171:27: error [SC001E]: 'p->cache' is nullable and no check narrows it: it goes through '->', which a null check does not follow; copy it to a local ('var c = p->cache') and check that
// DIAG-NOT: {{error|warning}}
