// A destructor declared `eval` is a Kairo error (SC290E). eval.mdx: a
// compile-time object is never destroyed, so it would never run. It reached
// clang, which reported "destructor cannot be declared consteval" on the
// emitted C++ twice and nothing at the Kairo source. Before that it crashed.

class S {
    pub var v: i32 = 1
    @move fn S(self, other: Self) = default
    eval fn op finally(self) { }
}

// A non-eval destructor beside eval members is fine.
class T {
    pub var v: i32 = 1
    @move fn T(self, other: Self) = default
    eval fn twice(self) -> i32 = self.v * 2
    fn op finally(self) { }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: eval_destructor.k:9:5: error [SC290E]: a destructor cannot be 'eval': a compile-time object is never destroyed
// CHECK-NOT: error
// RUN: %kairo --explain SC290E | %FileCheck %s --check-prefix=EXPLAIN
// EXPLAIN: 'eval' destructor
