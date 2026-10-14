// --cmax-union-width errors on a union with more members than the limit;
// 0 is unlimited (the registry minimum used to be 2, which made 0 unusable).
// Three members: a limit of 3 accepts, 2 rejects.

union U {
    var a: i32
    var b: u16
    var c: u8
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only --cmax-union-width=3 %s
// RUN: %kairo --type-check-only --cmax-union-width=0 %s
// RUN: { %kairo --type-check-only --cmax-union-width=2 %s 2>&1 || true; } | %FileCheck %s
// CHECK: cmax_union_width.k:5:{{[0-9]+}}: error [SC001E]: union has too many members (3, limit 2)
