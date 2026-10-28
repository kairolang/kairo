// IterLowering counts an array by its extent; for `[T; N]` over a generic
// value parameter that is the parameter, which it cannot spell yet, so the
// loop is SC116E rather than a loop over zero elements (EVAL.md 3). A
// diagnostic names such an array by its parameter.
class <eval N: usize> R {
    pub var items: [i32; N]
    fn sum(self) -> i32 { var s = 0  for x in self.items { s += x }  return s }
}

fn main() -> i32 {
    var bad: R<4> = 5
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK-DAG: value_generic_loop.k:7:47: error [SC116E]: iterating an array whose length is a generic value parameter is not yet supported
// CHECK-DAG: value_generic_loop.k:11:21: error [SC028E]: cannot convert 'i32' to 'R<4>'
