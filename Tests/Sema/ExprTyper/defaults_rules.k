// A default argument may not read a parameter or `self`, and may not be a
// slice literal. One line each, one error each.
fn a(x: i32, y: i32 = x) { }

class K {
    var v: i32
    fn m(self, y: i32 = self.v) { }
}

fn s(xs: [i32;] = [1, 2]) { }

fn ok(x: i32 = 1 + 2, v: [i32] = [1, 2]) { }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: defaults_rules.k:3:{{[0-9]+}}: error [SC106E]: a default argument cannot refer to parameter 'x'
// DIAG: defaults_rules.k:7:{{[0-9]+}}: error [SC106E]: a default argument cannot refer to 'self'
// DIAG: defaults_rules.k:10:{{[0-9]+}}: error [SC082E]: a list literal used as a default argument is a view of a temporary array
// DIAG-NOT: error
