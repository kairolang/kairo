// `static const` / `const static` makes the BINDING const, which `static`
// could not say before: a use of it types as `const T`, like a `const`
// binding's, in both orders and at every scope. Deeper const (a `*const T`
// pointee) is the type's business and unchanged.
//
// Assigning to one is not diagnosed by Sema yet: no const binding's is
// (TICKETS.TXT "Assigning to a `const` local is not diagnosed by Sema");
// clang refuses the generated assignment. The const type below is what a
// ConstChecking pass will read.

static const A = 1
const static B: i32 = 2
static S = 3

module m {
    pub const static MA = 4
}

fn f() -> i32 {
    static const LA = 5
    const static LB = 6
    return A + B + S + m::MA + LA + LB
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --print-sema 2>&1 || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA-LABEL: SEMA fid 0: {{.*}}static_const_binding.k
// SEMA: -- expression types --
// SEMA: <tu>::f
// SEMA: NamedIdentExpr @ 22:12 : const i32
// SEMA: NamedIdentExpr @ 22:16 : const i32
// SEMA: NamedIdentExpr @ 22:20 : i32
// SEMA: ChainExpr @ 22:24 : const i32
// SEMA: NamedIdentExpr @ 22:32 : const i32
// SEMA: NamedIdentExpr @ 22:37 : const i32
// SEMA: 0 errored
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
