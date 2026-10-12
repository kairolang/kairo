// A value form whose arms are all `void` has type `void`. As a statement that
// is fine; as an initializer it is the ordinary void-initializer error and
// nothing else.

fn f() { }
fn g() { }

fn statement(c: bool) {
    if c => f() else => g()
}

fn initializer(c: bool) {
    var x = if c => f() else => g()
// DIAG: void_arms.k:[[@LINE-1]]:{{[0-9]+}}: error [SC047E]: 'x' is initialized with an expression of type 'void'
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
