eval fn grid_size(n: usize) -> usize { return sizeof Grid<1> }
pub struct <eval N: usize> Grid {
    pub var cells: [i32; grid_size(N)]
}

eval fn pool_ok() -> bool { return sizeof Pool<i32> > 0 }
pub struct <T> Pool requires pool_ok() {
    pub var v: i32
}

eval fn other_size(n: usize) -> usize { return sizeof Other * n }
pub struct Other { pub var x: i64 }
pub struct <eval N: usize> Fine {
    pub var cells: [i32; other_size(N)]
}

fn main() -> i32 {
    var g = Grid<1>()
    var p = Pool<i32>()
    var f = Fine<2>()
    return 0
}

// EVAL.md §11 on a generic record: a computed field type, or a
// `requires` value predicate, evaluated in the record's definition from an
// eval item that needs an instance of the record complete has no order in
// any instance. Checked on the primary: before, the generic record was
// skipped and the field reached EmitPlan's toposort as an ICE. An item that
// needs another record only (Fine) is no cycle.
// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: eval_order_cycle_generic.k:3:20: error [SC195E]: this type has a value C++ computes from 'grid_size', which needs 'Grid' complete; inside its own definition 'Grid' is not complete yet, so no order of the C++ declarations can compute it
// CHECK-NEXT: eval_order_cycle_generic.k:1:47: note [SC195N]: 'grid_size' needs 'Grid' complete here
// CHECK-NEXT: eval_order_cycle_generic.k:7:30: error [SC195E]: this requires predicate is a value C++ computes from 'pool_ok', which needs 'Pool' complete
// CHECK-NEXT: eval_order_cycle_generic.k:6:36: note [SC195N]: 'pool_ok' needs 'Pool' complete here
