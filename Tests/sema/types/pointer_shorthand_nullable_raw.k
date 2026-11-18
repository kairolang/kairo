// `var unsafe *x = e` with `e: *T?` is ONE SC266E whose fix-it writes the
// whole `*x?`: the stars become safe and the `?` is added. Two separate
// fix-its, the `?` one keeping the written `unsafe *`, let a tool that
// applies only the first produce a nullable RAW pointer. Where the
// stars are already right, only the `?` is added.

class B { var x: i32 = 1 }
fn get(b: *B) -> *B? { return b }

fn main() -> i32 {
    var b = B()
    var unsafe *x = get(&b)
    var *y = get(&b)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: pointer_shorthand_nullable_raw.k:12:17: error [SC266E]: 'unsafe *x' is initialized with a nullable '*B?'; write '*x?' so the declaration says it may be null
// DIAG-NEXT: fix-it:{{.*}}:{12:9-12:17}:"*"
// DIAG-NEXT: fix-it:{{.*}}:{12:18-12:18}:"?"
// DIAG-NOT: {{error|warning}}
// DIAG: pointer_shorthand_nullable_raw.k:13:10: error [SC266E]: '*y' is initialized with a nullable '*B?'; write '*y?' so the declaration says it may be null
// DIAG-NEXT: fix-it:{{.*}}:{13:11-13:11}:"?"
// DIAG-NOT: {{error|warning}}
