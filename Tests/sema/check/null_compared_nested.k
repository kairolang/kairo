// A relational comparison with `&null` reads the literal as the other
// operand's pointer type and stores nothing, so it is not the "`&null` in a
// safe pointer" error (SC259E). That holds for the outer comparison when the
// other operand contains a comparison with `&null` of its own.

fn pick(b: bool, p: *i32) -> *i32 {
    return p
}

fn outer_after_inner(p: *i32, q: *i32) -> bool {
    return pick(q < &null, p) < &null
}

fn outer_before_inner(p: *i32, q: *i32) -> bool {
    return &null >= pick(&null >= q, p)
}

fn stored(q: *i32) -> bool {
    var p: *i32 = &null
// CHECK: null_compared_nested.k:[[@LINE-1]]:{{[0-9]+}}: error [SC259E]: '&null' cannot be stored in '*i32': a safe pointer is never null
    return p < q
}

fn main() -> i32 {
    var x: i32 = 1
    if outer_after_inner(&x, &x) || outer_before_inner(&x, &x) || stored(&x) {
        return 1
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
