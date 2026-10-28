pub struct Rec {
    pub var a: [i32; size_of_rec()]
}
eval fn size_of_rec() -> usize { return sizeof Rec }

pub struct Left {
    pub var a: [i32; right_size()]
}
pub struct Right {
    pub var l: Left
}
eval fn right_size() -> usize { return sizeof Right }

class Own {
    pub var a: [i32; Own::k()]
    eval fn k() -> usize { return 3 }
}

eval A: i32 = B + 1
eval B: i32 = A + 1
eval fn reads_c() -> i32 { return C }
eval C: i32 = reads_c()

eval fn fine() -> usize { return 2 }
pub struct Ok {
    pub var a: [i32; fine()]
}

fn main() -> i32 { return A + C }

// EVAL.md §11: a declaration's computed type is evaluated where C++ writes
// the declaration, after the eval items it names are defined (EmitPlan's
// early items). An item whose body needs the declaring record complete --
// directly (Rec), through another record that holds it by value (Left /
// Right), or as a member of it (Own) -- has no such order. Nor has an eval
// binding whose value reaches itself (A / B, and C through reads_c).
// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: eval_order_cycle.k:2:16: error [SC001E]: this type has a value C++ computes from 'size_of_rec', which needs 'Rec' complete; inside its own definition 'Rec' is not complete yet, so no order of the C++ declarations can compute it
// CHECK-NEXT: eval_order_cycle.k:4:41: note [SC001N]: 'size_of_rec' needs 'Rec' complete here
// CHECK-NEXT: eval_order_cycle.k:7:16: error [SC001E]: this type has a value C++ computes from 'right_size', which needs 'Right' complete, and 'Right' needs 'Left'; inside its own definition 'Left' is not complete yet
// CHECK-NEXT: eval_order_cycle.k:12:40: note [SC001N]: 'right_size' needs 'Right' complete here
// CHECK-NEXT: eval_order_cycle.k:15:16: error [SC001E]: this type has a value C++ computes from 'k', which needs 'Own' complete
// CHECK-NEXT: eval_order_cycle.k:16:5: note [SC001N]: 'k' needs 'Own' complete here
// CHECK-NEXT: eval_order_cycle.k:19:6: error [SC001E]: the value of 'eval A' depends on itself through 'B'; an eval binding cannot be computed from its own value
// CHECK-NEXT: eval_order_cycle.k:19:15: note [SC001N]: its initializer, which reads it back
// CHECK-NEXT: eval_order_cycle.k:20:6: error [SC001E]: the value of 'eval B' depends on itself through 'A'
// CHECK-NEXT: eval_order_cycle.k:20:15: note [SC001N]
// CHECK-NEXT: eval_order_cycle.k:22:6: error [SC001E]: the value of 'eval C' depends on itself through 'reads_c'
// CHECK-NEXT: eval_order_cycle.k:22:15: note [SC001N]
