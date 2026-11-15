// -Wconst-self over loops on a field: a loop whose binders would bind
// through `op in (const self)` only reads the field, whichever form it
// calls (r1..r4); `for *x` over a mutable vector, or `(k, *v)` over a
// map, may write the element and keeps SC273W quiet (m1, m2).

class C {
    var v: [i32]
    var m: {i32: i32}
    fn r1(self) -> i32 { var t = 0; for x in self.v { t += x }; return t }
    fn r2(self) -> i32 { var t = 0; for const x in self.v { t += x }; return t }
    fn r3(self) -> i32 { var t = 0; for const *x in self.v { t += *x }; return t }
    fn r4(self) -> i32 { var t = 0; for (k, v) in self.m { t += k + v }; return t }
    fn m1(self) { for *x in self.v { *x = 0 } }
    fn m2(self) { for (_, *v) in self.m { *v = 0 } }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only -Wconst-self 2>&1 || true; } | %FileCheck %s --implicit-check-not=SC273W --implicit-check-not=error
// CHECK-DAG: const_self_lint_iteration.k:9:11: warning [SC273W]: method 'r1' never mutates 'self'
// CHECK-DAG: const_self_lint_iteration.k:10:11: warning [SC273W]: method 'r2' never mutates 'self'
// CHECK-DAG: const_self_lint_iteration.k:11:11: warning [SC273W]: method 'r3' never mutates 'self'
// CHECK-DAG: const_self_lint_iteration.k:12:11: warning [SC273W]: method 'r4' never mutates 'self'
