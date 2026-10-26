// G12 (Compiler/Sema/NULLABLE.md 3.4): a call that may write a place the
// analysis cannot see the value of ends its check. Each `bad_*` reads a
// place the check proved, after a call that weakens it, and is the SC001E
// with a note naming that call; each `ok_*` is a use the rule leaves
// proven. Covered:
//   - an `@inout` argument, marked `&x`, unmarked (the tolerated, warned
//     form), on a field path (`&s.n`), on the path's owner (`&s` weakens
//     `s.n`), and through a function pointer (`g(&x)`);
//   - a non-const pointer passed (`mptr(&x)`): the pointer may be kept, so
//     the call weakens `x`, and so does every LATER call, while a check
//     with no call after it still narrows (3.7's escape rule);
//   - a write through a pointer to it (`*p = null`);
//   - NOT weakening: a `*const` pointer passed, a by-value pass, a check
//     after the weakening call;
//   - a weakening call in a loop body weakens the place at the loop's
//     head, since the back edge brings it there;
//   - a move out of a place is MoveCheck's: its use after the move is the
//     one SC052E, not a nullness error as well.
// The field-path rules (mutable `self`) are Sema/Nullable/weaken_fields.k.

class Mover { pub var n: i32 = 1; pub fn Mover(self) { } }
struct S { pub var n: i32? = null; pub var k: i32 = 0 }

fn bump(@inout x: i32?) { x = null }
fn bumps(@inout s: S) { s.n = null }
fn mptr(p: *(i32?)) { }
fn cptr(p: *const (i32?)) { }
fn byval(x: i32?) { }
fn noop() { }
fn consume(@move m: Mover?) { }

fn bad_inout() -> i32 {
    var x: i32? = 1
    bump(&x)
    return x + 0
}

fn bad_unmarked() -> i32 {
    var x: i32? = 1
    bump(x)
    return x + 0
}

fn bad_inout_field() -> i32 {
    var s = S()
    s.n = 1
    bump(&s.n)
    return s.n + 0
}

fn bad_inout_owner() -> i32 {
    var s = S()
    s.n = 1
    bumps(&s)
    return s.n + 0
}

fn bad_fn_pointer() -> i32 {
    var g = bump
    var x: i32? = 1
    g(&x)
    return x + 0
}

fn bad_pointer_passed() -> i32 {
    var x: i32? = 1
    mptr(&x)
    return x + 0
}

fn bad_escaped_later_call() -> i32 {
    var x: i32? = 1
    mptr(&x)
    if x? {
        var a = x + 0
        noop()
        return x + a
    }
    return 0
}

fn bad_write_through() -> i32 {
    var x: i32? = 1
    var p = &x
    *p = null
    return x + 0
}

fn ok_const_pointer() -> i32 {
    var x: i32? = 1
    cptr(&x)
    noop()
    return x + 0
}

fn ok_by_value() -> i32 {
    var x: i32? = 1
    byval(x)
    return x + 0
}

fn ok_recheck() -> i32 {
    var x: i32? = 1
    bump(&x)
    if x? { return x + 0 }
    return 0
}

fn ok_other_field() -> i32 {
    var s = S()
    s.n = 1
    bumps(&s)
    s.k = 2
    if s.n? { return s.n + s.k }
    return 0
}

fn moved() -> i32 {
    var m: Mover? = Mover()
    if m? {
        consume(m)
        return m.n
    }
    return 0
}

fn bad_loop_inout(c: i32) -> i32 {
    var x: i32? = 1
    var r = 0
    while r < c {
        r += x
        bump(&x)
    }
    return r
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG: weaken_calls.k:35:12: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: weaken_calls.k:34:11: note [{{.*}}]: this '@inout' argument lets the call change 'x'
// DIAG-NOT: {{error|warning}}
// DIAG: weaken_calls.k:40:10: warning [SC097W]: argument to '@inout' parameter 'x' is not marked with '&'; the marker will be required in a future release
// DIAG-NOT: {{error|warning}}
// DIAG: weaken_calls.k:41:12: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: weaken_calls.k:40:10: note [{{.*}}]: this '@inout' argument lets the call change 'x'
// DIAG-NOT: {{error|warning}}
// DIAG: weaken_calls.k:48:12: error [SC001E]: 's.n' may be null here; check it with 'if s.n?' first
// DIAG-NEXT: weaken_calls.k:47:11: note [{{.*}}]: this '@inout' argument lets the call change 's.n'
// DIAG-NOT: {{error|warning}}
// DIAG: weaken_calls.k:55:12: error [SC001E]: 's.n' may be null here; check it with 'if s.n?' first
// DIAG-NEXT: weaken_calls.k:54:12: note [{{.*}}]: this '@inout' argument lets the call change 's.n'
// DIAG-NOT: {{error|warning}}
// DIAG: weaken_calls.k:62:12: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: weaken_calls.k:61:8: note [{{.*}}]: this '@inout' argument lets the call change 'x'
// DIAG-NOT: {{error|warning}}
// DIAG: weaken_calls.k:68:12: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: weaken_calls.k:67:10: note [{{.*}}]: a pointer to 'x' escapes here; any call after it, or a write through it, may change 'x'
// DIAG-NOT: {{error|warning}}
// DIAG: weaken_calls.k:77:16: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: weaken_calls.k:73:10: note [{{.*}}]: a pointer to 'x' escapes here; any call after it, or a write through it, may change 'x'
// DIAG-NOT: {{error|warning}}
// DIAG: weaken_calls.k:86:12: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: weaken_calls.k:85:5: note [{{.*}}]: 'x' may be changed here, through a pointer to it
// DIAG-NOT: {{error|warning}}
// DIAG: weaken_calls.k:122:16: error [SC052E]: 'm' is used after being moved
// DIAG-NEXT: weaken_calls.k:121:17: note [{{.*}}]: 'm' was moved here, into a '@move' parameter
// DIAG-NEXT: weaken_calls.k:122:16: note [{{.*}}]: assign a new value to 'm' before using it again
// DIAG-NOT: {{error|warning}}
// DIAG: weaken_calls.k:131:14: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: weaken_calls.k:132:14: note [{{.*}}]: 'x' may be changed in the loop here, so it may be null at the top of the loop
// DIAG-NOT: {{error|warning}}
