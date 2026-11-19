// `@copy` / `@move` mark a copy or move constructor; on a free
// function they are misplaced. The constructors below are accepted.

@copy
fn free_copy() { }

@move
fn free_move() { }

class C {
    var x: i32

    @copy fn C(self, const other: Self) = default
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --error-format=basic 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: transfer_attr_free_fn.k:4:{{[0-9]+}}: error [SC143E]: '@copy' applies only to a copy or move constructor
// CHECK-DAG: transfer_attr_free_fn.k:7:{{[0-9]+}}: error [SC143E]: '@move' applies only to a copy or move constructor
// CHECK-NOT: transfer_attr_free_fn.k:{{1[0-9]}}:
