// An `eval` binding or `eval fn` resolves and types the same at file
// scope, in a module, in a class and in a function body: each is an
// ordinary declaration the name lookup finds (eval.mdx). At file scope and
// in a function body these used to parse as `eval <expr>`: `N` and the
// `eval fn`'s parameters were R020E "use of undeclared identifier".
// Compile-time evaluation itself is not checked here.

eval N = 10
eval M: i64 = 4
const eval C = 3
eval fn sq(x: i32) -> i32 { return x * x }

module m {
    pub eval K = 2
    pub eval fn cube(x: i32) -> i32 = x * x * x
}

class Cls {
    eval fn twice(self, x: i32) -> i32 = x + x
}

fn body(o: Cls) -> i32 {
    eval k: i32 = 4
    eval j = 5
    eval fn local(x: i32) -> i32 = x + 1
    return k + j + N + C + sq(2) + m::K + m::cube(2) + o.twice(1) + local(1)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --type-check-only --print-sema 2>&1 || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA-LABEL: SEMA fid 0: {{.*}}eval_decl_positions.k
// SEMA: -- name bindings --
// SEMA: <tu>::sq
// SEMA-NEXT: x @ 11:36 -> param x @ 11:12 [local frame 0]
// SEMA-NEXT: x @ 11:40 -> param x @ 11:12 [local frame 0]
// SEMA: <tu>::body::local
// SEMA-NEXT: x @ 25:36 -> param x @ 25:19 [local frame 1]
// SEMA: <tu>::body
// SEMA-NEXT: k @ 26:12 -> var k @ 23:5 [local frame 0]
// SEMA-NEXT: j @ 26:16 -> var j @ 24:5 [local frame 0]
// SEMA-NEXT: N @ 26:20 -> var N @ 8:1 [scope <tu>]
// SEMA-NEXT: C @ 26:24 -> var C @ 10:1 [scope <tu>]
// SEMA-NEXT: sq @ 26:28 -> fn sq @ 11:1 [scope <tu>]
// SEMA: ::K @ 26:39 -> var K @ 14:9
// SEMA: ::cube @ 26:46 -> fn cube @ 15:9
// SEMA: .twice @ 26:58 -> fn twice @ 19:5
// SEMA: local @ 26:69 -> fn local @ 25:5 [local frame 0]
// SEMA: -- inferred decls --
// SEMA-DAG: N : i32
// SEMA-DAG: C : i32
// SEMA-DAG: j : i32
// SEMA-DAG: K : i32
// SEMA: 0 unresolved
