// --help appends the rendered default only when the description does not
// already state one, so no line carries two "(default" groups, and -O keeps
// its "-O0 (default)" wording without a second default.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --help | %FileCheck %s
// CHECK: --xray <value>
// CHECK-SAME: (default: none)
// CHECK-NOT: (default: none) (default: none)
// RUN: %kairo --help | %FileCheck %s --check-prefix=OPT
// OPT: -O <value>
// OPT-SAME: -O0 (default)
// OPT-NOT: are -O1 (default: 0)
