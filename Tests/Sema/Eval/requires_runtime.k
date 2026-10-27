// A `requires` value predicate is an eval context (requires.mdx): one that
// reads a run-time value -- a parameter, a variable -- is the hard error
// "requires expression is not compile-time evaluable", labelled at the
// run-time part, with the note pointing at `where` (EVAL.md §8, E10).
// Conformance conjuncts (`T impl I`) are not predicates and pass.
var limit = 3
interface Shape { fn area(self) -> i32 }

fn divide(a: i32, b: i32) -> i32 requires b != 0 { return a / b }
fn bounded(x: i32) -> i32 requires limit > 2 { return x }
fn <T> both(x: T) -> i32 requires T impl Shape && sizeof T <= 64 { return 0 }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: requires_runtime.k:9:43: error [SC001E]: requires expression is not compile-time evaluable
// CHECK-NEXT: requires_runtime.k:9:43: note [SC001N]: for runtime-conditional dispatch, use 'where'
// CHECK: requires_runtime.k:10:36: error [SC001E]: requires expression is not compile-time evaluable
// CHECK-NEXT: requires_runtime.k:10:36: note [SC001N]: for runtime-conditional dispatch, use 'where'
