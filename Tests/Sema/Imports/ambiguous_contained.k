// An ambiguous import (R016E: a user `BigInt` beside the builtin prelude's)
// is CONTAINED: it poisons the uses of that one name and nothing else. It
// used to hard-stop the importing TU after I, so no signature in it was ever
// resolved and every caller of an unrelated generic method failed instead:
// "could not deduce every generic parameter" / "parameter type is
// unresolved" (self-host: one BigInt clash in ASTContext.k, ~230 SC063E on
// `ctx->alloc<Node>()`). The clash itself stays an error, reported once at
// the WRITTEN import with a note per candidate; a use of the name is
// poisoned without a second report.

// RUN: cd %S/Inputs/ambiguous_contained && { %kairo %s -I . --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["

// CHECK: Ctx.k:2:1: error [R016E]: ambiguous import: 'BigInt' names more than one non-function symbol
// CHECK-DAG: A.k:2:5: note [R016N]: 'BigInt' could be the class declared here
// CHECK-DAG: bigint.k:{{[0-9]+}}:{{[0-9]+}}: note [R016N]: 'BigInt' could be the struct declared here
// CHECK: ambiguous_contained.k:[[@LINE+3]]:1: error [R016E]: ambiguous import: 'BigInt' names more than one non-function symbol

import M::Ctx::*;
import M::A::*;

fn g(ctx: unsafe *Ctx) -> i32 {
    var a: unsafe *i32 = ctx->alloc<i32>();
    var c: unsafe *i32 = ctx->alloc_array<i32>(1);
    return ctx->h(1) + free_alloc<i32>(2);
}

// A use of the ambiguous name: poisoned, no second R016E and no cascade.
fn use_it() -> i32 {
    var b: BigInt;
    return 0;
}
