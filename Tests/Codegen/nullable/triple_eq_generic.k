// `===` on nullables compares the values with their `==`, one level down
// on nullable pointers (nullables.mdx, Null-aware equality). In a generic
// body that `==` is T's, and under MONO.md D0 T has only what its bounds
// grant: an unbounded `T` has no `==`, so `same` is refused at its
// definition. This test used to be an XFAIL asking that `same` at
// `T = *i32` compare the pointees; that is not expressible under D0
// (nothing a bound says makes T a pointer, and the body is typed once), so
// the decision (MONO.md G11) is the error below. With a bound declaring
// `op ==`, `===` on a `T?` runs through the bound's witness
// (witness/bound_ops.k); a `(*T)?` written as such compares pointees, whose
// `==` is again T's.

fn <T> same(a: T?, b: T?) -> bool = a === b
fn <T> same_pointee(a: (*T)?, b: (*T)?) -> bool = a === b

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error
// DIAG: triple_eq_generic.k:13:37: error [R051E]: '===' on 'T?' compares the values with 'op ==', so it needs a bound on 'T' that declares 'op =='
// DIAG: triple_eq_generic.k:14:51: error [R051E]: '===' on '*T?' compares the values with 'op ==', so it needs a bound on 'T' that declares 'op =='
