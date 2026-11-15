// `L<Args>::Member` with L a Kairo generic record: the member type is found
// on the body the instance selects and reads the instance's arguments; a
// name that body does not declare is "no type named", reported once at the
// segment; a module path that misses reports the same way.

struct <T> L {
    struct P { var k: T }
    type A = T
}

module m {
    struct Q { var z: i32 }
}

fn f() -> i32 {
    var a = L<i32>::P{ k: 1 }
    var b: L<i32>::A = a.k
    var c: L<i32>::Missing
    var d: m::Q
    var e: m::Missing
    return b
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{:1[67]:.*}}error
// DIAG: {{.*}}:18:20: error [R025E]: no type named 'Missing' in 'L'
// DIAG-NOT: {{:19:.*}}error
// DIAG: {{.*}}:20:15: error [R025E]: no type named 'Missing' in 'm'
// DIAG-NOT: error
