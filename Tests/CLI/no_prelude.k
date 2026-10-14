// --no-prelude stops the builtin module from being loaded, so a builtin name
// such as Ordering is undeclared. Without the flag it resolves.

fn f() -> i32 { var o = Ordering::Less; return 0 }
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo --type-check-only %s 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=DEFAULT
// DEFAULT-NOT: error
// DEFAULT: exit 0
// RUN: { %kairo --type-check-only --no-prelude %s 2>&1 || true; } | %FileCheck %s --check-prefix=NOPRELUDE
// NOPRELUDE: error [R020E]: {{.*}}Ordering
