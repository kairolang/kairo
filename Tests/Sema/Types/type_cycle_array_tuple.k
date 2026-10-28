// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// A fixed array stores its elements and a tuple stores its members, so both
// are by-value edges. See type_cycle_direct.k for the map.

struct Arr  { var a: [Arr2; 4]; }
struct Arr2 { var t: (i32, Arr); }
// DIAG: SC002E{{.*}}'Arr' contains itself by value
// DIAG: 'Arr' holds 'Arr2' by value
// DIAG: 'Arr2' holds 'Arr' by value, closing the cycle

fn main() -> i32 { return 0; }

// DIAG-NOT: SC002E
