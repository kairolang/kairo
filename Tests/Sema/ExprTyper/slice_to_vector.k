// `[T;] -> [T]` allocates, so it is written: `s as [i32]`, through Vector's
// converting constructor. A literal never needs it; it is typed as the vector.

fn takes_vec(const xs: [i32]) -> i32 { return 0 }

fn written(const s: [i32;]) -> i32 { return takes_vec(s as [i32]) }
fn literal() -> i32 { return takes_vec([1, 2, 3]) }
fn silent(const s: [i32;]) -> i32 { return takes_vec(s) }

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: no matching overload for call to 'takes_vec'
// DIAG: candidate not viable: cannot convert argument of type
// DIAG-NOT: error
