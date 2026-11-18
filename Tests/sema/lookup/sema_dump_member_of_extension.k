// --print-sema names the type an `extend` block's member belongs to (GH#76):
// a member found in `extend i32 { ... }` printed "[member of ]", since the
// extension decl has no name and i32 has no decl. It prints the
// extended type, as a record's member prints the record.

extend i32 {
    fn twice(self) -> i32 {
        return self + self
    }
}

struct P { var v: i32 }

extend P {
    fn get(const self) -> i32 = self.v
}

fn use_it() -> i32 {
    var x: i32 = 5
    var p = P { v: 1 }
    return x.twice() + p.get()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --print-sema 2>&1 || true; } | %FileCheck %s --implicit-check-not="[member of ]"
// CHECK: member  .twice {{.*}} -> fn twice @ 7:5  [member of i32]
// CHECK: member  .get {{.*}} -> fn get @ 15:5  [member of P]
