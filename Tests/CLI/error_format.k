// --error-format picks the diagnostic consumer: basic is one line per
// diagnostic with the code, pretty is the multi-line renderer. %kairo already
// passes basic, so the pretty run overrides it to prove the flag selects.

fn main() -> i32 { return undefined_thing }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s
// CHECK: error_format.k:{{[0-9]+}}:{{[0-9]+}}: error [R020E]: use of undeclared identifier 'undefined_thing'
// RUN: { %kairo --error-format=pretty --type-check-only %s 2>&1 || true; } | %FileCheck %s --check-prefix=PRETTY
// PRETTY-NOT: error_format.k:{{[0-9]+}}:{{[0-9]+}}: error
// PRETTY: undefined_thing
