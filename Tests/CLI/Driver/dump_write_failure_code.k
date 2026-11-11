// RUN: mkdir -p %t.d
// RUN: { %kairo %s --type-check-only --dump-import-uses=%t.d 2>&1 || true; } | %FileCheck %s --check-prefix=USES
// RUN: { %kairo %s --type-check-only --dump-interface=%t.d 2>&1 || true; } | %FileCheck %s --check-prefix=IFACE
// RUN: { %kairo %s --type-check-only --dump-deps=%t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DEPS
// A failed dump write is the generic "cannot write an output file" code
// (U023E), not U022E ("cannot write C++ header") and not a placeholder.
// USES: error [U023E]: cannot write import-use dump
// IFACE: error [U023E]: cannot write interface dump
// DEPS: error [U023E]: cannot write dependency dump
fn main() -> i32 { return 0 }
