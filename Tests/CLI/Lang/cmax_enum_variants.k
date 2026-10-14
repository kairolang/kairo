// --cmax-enum-variants errors on an enum with more variants than the limit;
// 0 is unlimited. Three variants: a limit of 3 accepts, 2 rejects.

enum Color { Red, Green, Blue }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only --cmax-enum-variants=3 %s
// RUN: %kairo --type-check-only --cmax-enum-variants=0 %s
// RUN: { %kairo --type-check-only --cmax-enum-variants=2 %s 2>&1 || true; } | %FileCheck %s
// CHECK: cmax_enum_variants.k:4:{{[0-9]+}}: error [SC001E]: enum has too many variants (3, limit 2)
