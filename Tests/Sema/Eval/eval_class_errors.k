// An `eval` constant is a compile-time object, which is never destroyed:
// its type has no user-written destructor. A generic value parameter takes
// an integer type only for now (an eval class as one is EVAL.md 7e).
class Res { pub var v: i32  eval fn Res(self) { self.v = 1 }  fn op delete(self) { } }
class Cfg { pub var w: i32  eval fn Cfg(self, w: i32) { self.w = w } }
eval R = Res()
fn <eval C: Cfg> use_cfg() -> i32 { return 0 }
fn <eval B: bool> flag() -> i32 { return 0 }
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: eval_class_errors.k:6:6: error [SC001E]: 'R' is an 'eval' constant of type 'Res', whose destructor is not trivial; a compile-time object is never destroyed
// CHECK-NEXT: eval_class_errors.k:4:63: note [SC001N]: the destructor is declared here
// CHECK: eval_class_errors.k:7:13: error [SC116E]: a generic value parameter of type 'Cfg' is not yet supported; only an integer type is
// CHECK: eval_class_errors.k:8:13: error [SC116E]: a generic value parameter of type 'bool' is not yet supported; only an integer type is
