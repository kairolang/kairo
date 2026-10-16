// A finally body sees exactly what a statement at its position sees: the
// names declared above it, not ones declared later in the block, even
// though it runs at the block's end.

fn later_decl() {
    finally { use_me = 1 }
    var use_me = 0
}

fn earlier_decl() {
    var seen = 0
    finally { seen = 1 }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: error
// CHECK: finally_names.k:6:15: error [R020E]: use of undeclared identifier 'use_me'
// CHECK-NOT: error
