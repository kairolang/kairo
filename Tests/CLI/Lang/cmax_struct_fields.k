// --cmax-struct-fields errors on a struct or class with more fields than the
// limit; 0 is unlimited. Three fields: a limit of 3 accepts, 2 rejects.

struct P {
    var a: i32
    var b: i32
    var c: i32
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only --cmax-struct-fields=3 %s
// RUN: %kairo --type-check-only --cmax-struct-fields=0 %s
// RUN: { %kairo --type-check-only --cmax-struct-fields=2 %s 2>&1 || true; } | %FileCheck %s
// CHECK: cmax_struct_fields.k:4:{{[0-9]+}}: error [SC001E]: struct has too many fields (3, limit 2)
