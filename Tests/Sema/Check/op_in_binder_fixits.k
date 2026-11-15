// The edits SC298E offers, and SC275W over a value-yielding `op in`.
//
// A change of `const` is offered only inside the binder's own range: a
// lone binder written right after `for ` gains `const `, an element of a
// binder list gains its own `const `, and a binder under a header keyword
// (`for var *x`) gets no edit, since `for var const *x` is no binder.
// SC275W over a value yield names the `-> yield *T` the element needs and
// offers no `*`, which SC298E would refuse.

class CPtr {
    var a: i32 = 1

    fn op in (const self) -> yield *const i32 {
        yield &self.a
    }
}

class CPairs {
    var p: (i32, i32) = (1, 2)

    fn op in (const self) -> yield *const (i32, i32) {
        yield &self.p
    }
}

class Val {
    var a: i32 = 1

    fn op in (self) -> yield i32 {
        yield self.a
    }
}

fn fixits(const c: CPtr, const ps: CPairs, v: Val) -> i32 {
    var s = 0
    // CHECK: op_in_binder_fixits.k:[[@LINE+2]]:9: error [SC298E]: 'for *x' does not bind
    // CHECK-NEXT: fix-it:"{{.*}}op_in_binder_fixits.k":{[[@LINE+1]]:9-[[@LINE+1]]:11}:"const *x"
    for *x in c { s += *x }
    // CHECK: op_in_binder_fixits.k:[[@LINE+2]]:13: error [SC298E]: the binder '*b' does not bind
    // CHECK-NEXT: fix-it:"{{.*}}op_in_binder_fixits.k":{[[@LINE+1]]:13-[[@LINE+1]]:15}:"const *b"
    for (a, *b) in ps { s += a + *b }
    // CHECK: op_in_binder_fixits.k:[[@LINE+2]]:13: error [SC298E]: 'for *y' does not bind
    // CHECK-NOT: fix-it
    for var *y in c { s += *y }
    // CHECK: op_in_binder_fixits.k:[[@LINE+4]]:9: warning [SC275W]: this writes to a copy of the element; the collection is not changed
    // CHECK-NOT: fix-it
    // CHECK: note [SC275N]: 'w' is bound by value here, and this 'op in' yields values; with '-> yield *T' a 'for *w' would point at the element
    for w in v {
        w = 2
    }

    return s
}

fn main() -> i32 {
    return 0
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
