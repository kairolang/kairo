// An expression-bodied function is the block it abbreviates
// (Sema/Lower/ExprBodyDesugar.k): `-> T = e` returns `e`, and a body with no
// written return type runs `e` for its effect. Free functions and methods in
// an extend both reach codegen as blocks; before the pass, EmitIR ICEd on
// the first one it met.

struct Vec2 {
    var x: i32
    var y: i32
}

extend Vec2 {
    fn dot(const self, o: Vec2) -> i32 = self.x * o.x + self.y * o.y
}

fn add(a: i32, b: i32) -> i32 = a + b
fn bump(@inout n: i32) = n += 1

fn main() -> i32 {
    var a = Vec2 { x: 1, y: 2 }
    var b = Vec2 { x: 3, y: 4 }
    var n = 0
    bump(&n)
    return add(a.dot(b), n)          // 11 + 1 == 12
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
//
// A written return type returns the expression; no written type runs it.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: CODEGEN C++: {{.*}}functions/expr_body.k
// IR-DAG: return {{.*}}self{{.*}}x{{.*}}o{{.*}}x
// IR-DAG: return {{.*}}a{{.*}}+{{.*}}b
// IR-NOT: expression-bodied
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 12
