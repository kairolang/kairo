// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// A base contributes its whole layout, so `derives` is a by-value edge.
// `implements` is not: an interface is structural and carries no storage.
// See type_cycle_direct.k for the map.

class Base derives Leaf { }
class Leaf derives Base { }
// DIAG: SC002E{{.*}}'Base' contains itself by value
// DIAG: 'Base' holds 'Leaf' by value
// DIAG: 'Leaf' holds 'Base' by value, closing the cycle

fn main() -> i32 { return 0; }

// DIAG-NOT: SC002E
