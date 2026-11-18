// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// A cycle two hops long: A holds B, B holds A. Reported once, at the first
// record, with the whole path as notes. See type_cycle_direct.k for the map.

class A { var b: B; }
class B { var a: A; }
// DIAG: SC002E{{.*}}'A' contains itself by value
// DIAG: 'A' holds 'B' by value
// DIAG: 'B' holds 'A' by value, closing the cycle

fn main() -> i32 { return 0; }

// DIAG-NOT: SC002E
