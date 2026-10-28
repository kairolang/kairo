// Panics outside a function body (PANIC.md §4.5).
// - A global's or a static field's initializer runs at file scope: no
//   function to propagate to, and no statement expression for a `try`. It
//   holds no `panic`, no panicking call and no `try`, handled or not.
// - A field's default and a parameter's default let nothing leave: a
//   panicking call there must be handled (here, with `try`).
// - A local `static` is its function's: C++ runs its initializer inside it.

struct E { var code: i32 }

fn thrower() panic -> i32 { panic E { code: 1 } }

var g = thrower()
var h = try thrower() catch => 0

class Cfg {
    static s: i32 = thrower()
    var a: i32 = thrower()
    var b: i32 = try thrower() catch => 0
}

fn defaulted(x: i32 = thrower(), y: i32 = try thrower() catch => 0) -> i32 { return x + y }

fn local_static() panic -> i32 {
    static once: i32 = thrower()
    return once
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: initializers.k:13:9: error [SC001E]: a global's initializer cannot panic: 'thrower' may panic with 'E', and there is no function to propagate to
// CHECK-NEXT: initializers.k:11:1: note [SC001N]: 'thrower' is declared 'panic' here
// CHECK-NEXT: initializers.k:13:1: note [SC001N]: initialize it in a function instead
// CHECK: initializers.k:14:9: error [SC001E]: a global's initializer cannot hold a 'try': it runs at file scope, outside every function
// CHECK-NEXT: initializers.k:14:1: note [SC001N]: initialize it in a function instead
// CHECK: initializers.k:14:13: error [SC001E]: a global's initializer cannot panic: 'thrower' may panic with 'E', and there is no function to propagate to
// CHECK-NEXT: initializers.k:11:1: note [SC001N]: 'thrower' is declared 'panic' here
// CHECK-NEXT: initializers.k:14:1: note [SC001N]: initialize it in a function instead
// CHECK: initializers.k:17:21: error [SC001E]: a global's initializer cannot panic: 'thrower' may panic with 'E', and there is no function to propagate to
// CHECK-NEXT: initializers.k:11:1: note [SC001N]: 'thrower' is declared 'panic' here
// CHECK-NEXT: initializers.k:17:5: note [SC001N]: initialize it in a function instead
// CHECK: initializers.k:18:18: error [SC001E]: a field's default cannot panic: 'thrower' may panic with 'E', which is not handled
// CHECK-NEXT: initializers.k:11:1: note [SC001N]: 'thrower' is declared 'panic' here
// CHECK-NEXT: initializers.k:18:18: note [SC001N]: or handle it here
// CHECK-NEXT: fix-it:"{{.*}}initializers.k":{18:18-18:18}:"try "
// CHECK-NEXT: fix-it:"{{.*}}initializers.k":{18:27-18:27}:" catch => crash!()"
// CHECK-NEXT: initializers.k:18:5: note [SC001N]: the default is declared here
// CHECK: initializers.k:22:23: error [SC001E]: a parameter's default cannot panic: 'thrower' may panic with 'E', which is not handled
// CHECK-NEXT: initializers.k:11:1: note [SC001N]: 'thrower' is declared 'panic' here
// CHECK-NEXT: initializers.k:22:23: note [SC001N]: or handle it here
// CHECK-NEXT: fix-it:"{{.*}}initializers.k":{22:23-22:23}:"try "
// CHECK-NEXT: fix-it:"{{.*}}initializers.k":{22:32-22:32}:" catch => crash!()"
// CHECK-NEXT: initializers.k:22:14: note [SC001N]: the default is declared here
