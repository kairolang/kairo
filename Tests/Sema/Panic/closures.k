// A closure is its own body (PANIC.md §2.1): what it panics with is ITS
// set, not the enclosing function's. With no `panic` it lets nothing
// leave (edit: mark the closure `panic`); a declared set lets only that
// leave; a bare `panic` infers. Making a closure is not a call: the
// enclosing function needs nothing for it.

struct E { var code: i32 }
struct F { var code: i32 }

fn thrower() panic(E) -> i32 { panic E { code: 1 } }

fn makes() -> i32 {
    var quiet  = fn () -> i32 { return thrower() }
    var narrow = fn () panic(F) -> i32 { return thrower() }
    var exact  = fn () panic(E) -> i32 { return thrower() }
    var guess  = fn () panic -> i32 { return thrower() }
    var caught = fn () -> i32 { return try thrower() catch => 0 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: closures.k:13:40: error [SC001E]: unhandled panic: 'thrower' may panic with 'E', and the closure is not marked 'panic'
// CHECK-NEXT: fix-it:"{{.*}}closures.k":{13:23-13:23}:" panic"
// CHECK-NEXT: closures.k:10:1: note [SC001N]: 'thrower' is declared 'panic' here
// CHECK-NEXT: closures.k:13:40: note [SC001N]: or handle it here
// CHECK-NEXT: fix-it:"{{.*}}closures.k":{13:40-13:40}:"try "
// CHECK-NEXT: fix-it:"{{.*}}closures.k":{13:49-13:49}:" catch => crash!()"
// CHECK: closures.k:14:49: error [SC001E]: 'E' is not in the declared panic set of the closure
// CHECK-NEXT: fix-it:"{{.*}}closures.k":{14:31-14:31}:", E"
// CHECK-NEXT: closures.k:10:1: note [SC001N]: 'thrower' is declared 'panic' here
