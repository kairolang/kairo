fn sum(...xs: i32) -> usize { return xs.len }
fn first(...xs: i32) -> i32 { return xs.data[0] }
fn <T> gen(...xs: T) -> usize { return xs.len }   // generic pack: deferred, no error

// --- lit wiring -----------------------------------------------------------
// Inside its function a pack `...xs: T` is a slice `[T;]` over the run of
// arguments; the parameter's declared type stays the element, so only reads
// of the name see the slice. A generic pack has no slice until M2 and stays
// deferred rather than erroring.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}pack_body.k
// SEMA: .len {{.*}}-> field len
// SEMA: NamedIdentExpr {{.*}}@ 1:{{[0-9]+}} {{ *}}: [i32;]
