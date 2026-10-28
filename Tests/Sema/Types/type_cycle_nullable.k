// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// `T?` is `Nullable<T>`, which stores the T itself (NULLABLE.md 1.2: tagged
// storage; a niche would still be the T), so a nullable of the record is a
// by-value edge. A nullable POINTER is the way to say "maybe a next one";
// that half is in type_cycle_indirection.k. See type_cycle_direct.k for the map.

class ByNullable { var next: ByNullable?; }
// DIAG: SC002E{{.*}}'ByNullable' contains itself by value
// DIAG: 'ByNullable' holds 'ByNullable' by value, closing the cycle

fn main() -> i32 { return 0; }

// DIAG-NOT: SC002E
