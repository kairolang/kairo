// Two `op as` to the SAME target are one member declared twice (R041E),
// whatever their bodies: the target is the overload's whole identity. The
// diagnostic names the operator, 'op as' (it used to say 'op'). Different
// targets beside them are fine.

class Dup {
    var c: i32
    fn Dup(self, c: i32) { self.c = c }
    fn op as(self) -> i32 { return self.c }
    fn op as(self) -> i64 { return 0 }
    fn op as(self) -> i32 { return 0 }
}

fn main() -> i32 { return 0 }

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:11:5: error [R041E]: class member 'op as' cannot be redeclared
// DIAG-NEXT: {{.*}}:9:5: note [R041N]: previous declaration is here
// END-GENERATED-CHECKS(DIAG)
