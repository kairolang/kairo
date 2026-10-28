// G13 (Compiler/Sema/NULLABLE.md 3.5): a loop body is typed once, from the
// state at the loop's head, so that state must hold on every back edge. A
// place proven before the loop stays proven at the head unless some path
// through the body may bring it back holding anything else; that is found
// by a pre-scan of the body, path by path. Each `ok_*` below has no error;
// each `bad_*` has exactly one, at the marked read. Covered:
//   - the body assigns only values known non-null (a scalar expression, a
//     call declared to return `T`, a literal): still proven at the head;
//   - the body sets it to null and then to a value again before the back
//     edge: still proven; with a `continue` between the two, the continue
//     brings the null back, and it is not;
//   - the body assigns a value that may be null: not proven at the head;
//   - `while x?` proves `x` at the top of its body even though the body
//     reassigns it from a nullable;
//   - after a `while`: its condition's false set (`x` null after
//     `while x?`), joined with each `break` (`x = 3` before a break does not
//     prove it when the loop may not run at all); a `loop {}` left only by
//     a break that proved it;
//   - a `for` over a range: no condition refines it; a body that leaves it
//     alone keeps it, one that nulls it does not;
//   - an indexed `for` whose update writes it;
//   - nested loops: an inner loop that may leave it null loses it at the
//     outer head; one whose null is overwritten before its only break does
//     not;
//   - labeled `break outer` joins into `outer`, not into the inner loop:
//     after an outer `while` it may not have run; after an outer `loop` the
//     labeled break is the only exit.
// Weakening calls in a loop are in Sema/Nullable/weaken_*.k; the run is
// Codegen/nullable/loops.k.

fn find(k: i32) -> i32? { if k > 0 { return k } return null }
fn val(k: i32) -> i32 { return k }

class Node { pub var v: i32 = 1; pub var next: (*Node)? = null }

fn ok_values(n: i32) -> i32 {
    var x: i32? = 1
    var r = 0
    while r < n {
        r += x
        x = r + 1
        x = val(r)
        x = 7
    }
    return r + x
}

fn ok_reestablished(n: i32) -> i32 {
    var x: i32? = 1
    var r = 0
    while r < n {
        r += x
        x = null
        x = 5
    }
    return r
}

fn bad_continue_between(n: i32) -> i32 {
    var x: i32? = 1
    var r = 0
    while r < n {
        r += x
        x = null
        if r > 2 { continue }
        x = 5
    }
    return r
}

fn bad_maybe(n: i32) -> i32 {
    var x: i32? = 1
    var r = 0
    while r < n {
        r += x
        x = find(r)
    }
    return r
}

fn ok_while_test(h: (*Node)?) -> i32 {
    var *node? = h
    var r = 0
    while node? {
        r += node->v
        node = node->next
    }
    return r
}

fn bad_after_while(h: i32?) -> i32 {
    var x? = h
    while x? { x = find(x - 1) }
    return x + 0
}

fn bad_break_join(n: i32) -> i32 {
    var x: i32? = null
    var r = 0
    while r < n {
        x = 3
        if r > 1 { break }
        r += 1
    }
    return x + 0
}

fn ok_loop_break() -> i32 {
    var x: i32? = null
    loop {
        x = find(2)
        if x? { break }
    }
    return x + 0
}

fn ok_for_range(n: i32) -> i32 {
    var x: i32? = 1
    var r = 0
    for k in 0..n { r += x + k }
    return r + x
}

fn bad_for_range(n: i32) -> i32 {
    var x: i32? = 1
    var r = 0
    for k in 0..n {
        r += x
        x = find(k)
    }
    return r
}

fn bad_indexed_update(n: i32) -> i32 {
    var x: i32? = 1
    var r = 0
    for var i = 0; i < n; x = find(i) {
        r += x
        i += 1
    }
    return r
}

fn bad_nested(n: i32) -> i32 {
    var x: i32? = 1
    var r = 0
    while r < n {
        r += x
        var j = 0
        while j < n {
            x = find(j)
            j += 1
        }
        r += 1
    }
    return r
}

fn ok_inner_break(n: i32) -> i32 {
    var x: i32? = 1
    var r = 0
    while r < n {
        r += x
        loop {
            x = null
            x = 2
            break
        }
        r += 1
    }
    return r
}

fn bad_labeled_while(n: i32) -> i32 {
    var x: i32? = null
    var r = 0
    outer: while r < n {
        r += 1
        while true {
            x = 4
            break outer
        }
    }
    return x + 0
}

fn ok_labeled_loop() -> i32 {
    var x: i32? = null
    outer: loop {
        while true {
            x = 4
            break outer
        }
    }
    return x + 0
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG: loops.k:63:14: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: loops.k:64:9: note [{{.*}}]: 'x' may be changed in the loop here, so it may be null at the top of the loop
// DIAG-NOT: {{error|warning}}
// DIAG: loops.k:75:14: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: loops.k:76:9: note [{{.*}}]: 'x' may be changed in the loop here, so it may be null at the top of the loop
// DIAG-NOT: {{error|warning}}
// DIAG: loops.k:94:12: error [SC001E]: 'x' is always null here
// DIAG-NEXT: loops.k:93:11: note [{{.*}}]: on this path, the test here found 'x' null
// DIAG-NOT: {{error|warning}}
// DIAG: loops.k:105:12: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: loops.k:100:17: note [{{.*}}]: 'x' may be changed in the loop here, so it may be null at the top of the loop
// DIAG-NOT: {{error|warning}}
// DIAG: loops.k:128:14: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: loops.k:129:9: note [{{.*}}]: 'x' may be changed in the loop here, so it may be null at the top of the loop
// DIAG-NOT: {{error|warning}}
// DIAG: loops.k:138:14: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: loops.k:137:27: note [{{.*}}]: 'x' may be changed in the loop here, so it may be null at the top of the loop
// DIAG-NOT: {{error|warning}}
// DIAG: loops.k:148:14: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: loops.k:151:13: note [{{.*}}]: 'x' may be changed in the loop here, so it may be null at the top of the loop
// DIAG-NOT: {{error|warning}}
// DIAG: loops.k:184:12: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: loops.k:175:5: note [{{.*}}]: 'x' is declared nullable here
// DIAG-NOT: {{error|warning}}
