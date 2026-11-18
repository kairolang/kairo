// SC275W over a loop whose binder could not be a `*x`: a map's key (a
// `*const K` element), a set's element, an element of a const vector, a
// value element of a tuple yield. The note says the loop cannot write the
// element and offers no `*`, which SC298E would refuse. Over a mutable
// vector's element the `*` stays the fix.

class Tagged {
    var vals: [i32; 2] = [5, 6]

    fn op in (self) -> yield (usize, *i32) {
        for var i: usize = 0; i < 2; ++i {
            yield (i, &self.vals[i])
        }
    }
}

fn lint(m: {i32: i32}, const st: {i32}, const cv: [i32], v: [i32], g: Tagged) {
    for (k, _) in m {
        // CHECK: op_in_copy_lint_readonly.k:[[@LINE+3]]:9: warning [SC275W]: this writes to a copy of the element
        // CHECK-NOT: fix-it
        // CHECK: note [SC275N]: 'k' is bound by value here, and this loop cannot write the element: 'op in' yields it read-only or by value
        k = 1
    }

    for x in st {
        // CHECK: op_in_copy_lint_readonly.k:[[@LINE+3]]:9: warning [SC275W]
        // CHECK-NOT: fix-it
        // CHECK: note [SC275N]: 'x' is bound by value here, and this loop cannot write the element
        x = 1
    }

    for x in cv {
        // CHECK: op_in_copy_lint_readonly.k:[[@LINE+3]]:9: warning [SC275W]
        // CHECK-NOT: fix-it
        // CHECK: note [SC275N]: 'x' is bound by value here, and this loop cannot write the element
        x = 1
    }

    for (i, _) in g {
        // CHECK: op_in_copy_lint_readonly.k:[[@LINE+3]]:9: warning [SC275W]
        // CHECK-NOT: fix-it
        // CHECK: note [SC275N]: 'i' is bound by value here, and this loop cannot write the element
        i = 1
    }

    for x in v {
        // CHECK: op_in_copy_lint_readonly.k:[[@LINE+2]]:9: warning [SC275W]
        // CHECK-NEXT: fix-it:"{{.*}}op_in_copy_lint_readonly.k":{[[@LINE-2]]:9-[[@LINE-2]]:9}:"*"
        x = 1
    }
}

fn main() -> i32 {
    return 0
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
