// A script's top level is main's body (SCRIPT.md, PANIC.md §2.4): nothing
// may reach it. A deferred binding's initializer runs at its line in main,
// so it follows the same rule -- and, unlike a module's global, it may use
// `try`.

struct E { var code: i32 }

fn thrower() panic -> i32 { panic E { code: 1 } }

var a = thrower()
var b = try thrower() catch => 0
a = a + thrower()

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: script.k:10:9: error [SC001E]: a panic cannot reach a script's top level: 'thrower' may panic with 'E', which is not handled
// CHECK-NEXT: script.k:8:1: note [SC001N]: 'thrower' is declared 'panic' here
// CHECK-NEXT: script.k:10:9: note [SC001N]: or handle it here, or stop the program with 'crash!()'
// CHECK-NEXT: fix-it:"{{.*}}script.k":{10:9-10:9}:"try "
// CHECK-NEXT: fix-it:"{{.*}}script.k":{10:18-10:18}:" catch => crash!()"
// CHECK: script.k:12:9: error [SC001E]: a panic cannot reach a script's top level: 'thrower' may panic with 'E', which is not handled
// CHECK-NEXT: script.k:8:1: note [SC001N]: 'thrower' is declared 'panic' here
// CHECK-NEXT: script.k:12:9: note [SC001N]: or handle it here, or stop the program with 'crash!()'
// CHECK-NEXT: fix-it:"{{.*}}script.k":{12:9-12:9}:"try "
// CHECK-NEXT: fix-it:"{{.*}}script.k":{12:18-12:18}:" catch => crash!()"
