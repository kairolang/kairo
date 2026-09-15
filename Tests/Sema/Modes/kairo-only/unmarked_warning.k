fn bump(@inout x: i32) { x = x + 1; }
fn main() {
    var n = 0;
    bump(n);                                // expect: warning SC001W ... not marked with '&' ... will be required
    bump(&n);                               // expect: clean
    bump(3);                                // expect: error no matching overload: parameter 'x' is '@inout' and needs a mutable lvalue
    const k = 1;
    bump(&k);                               // expect: error no matching overload (const lvalue does not bind)
}
// expect: the call on line 4 still binds (dump shows bump resolved) and is not poisoned

// --- lit wiring -----------------------------------------------------------
// KAIRO-ONLY. An unmarked argument to `@inout` is viable (migration
// tolerance) and warned after selection; a prvalue or a const lvalue never
// binds, marked or not.
//
// The second RUN proves the warned call still BINDS and is not poisoned:
// `bump` at 4:5 resolves, and the call is typed `void`, not <ERROR>.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// SEMA:      -- name bindings --
// SEMA:      bump @ 4:5 -> fn bump @ 1:1
// SEMA:      -- expression types --
// SEMA:      CallExpr @ 4:5 : void
//
// DIAG-DAG: unmarked_warning.k:4:{{[0-9]+}}: warning [SC001W]: {{.*}}'&'
// DIAG-DAG: unmarked_warning.k:6:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG-DAG: {{.*}}parameter 'x' is '@inout' and needs a mutable lvalue
// DIAG-DAG: unmarked_warning.k:8:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG-NOT: unmarked_warning.k:5:{{[0-9]+}}: {{error|warning}}
