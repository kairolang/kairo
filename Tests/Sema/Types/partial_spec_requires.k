// Sema/Types/partial_spec_requires.k
// NULLABLE.md G0: `struct <P> X<P> requires pred` beside a primary `X` -- the
// v3 draft's NullableStorage form -- is a partial specialization selected by
// its clause alone. Its pattern is the head's own parameters, so it parses as
// a second primary; it was R029E "redefinition", which names the wrong
// problem. Requires-dispatch is not built, so it is refused as such (the same
// SC001E as the `<*P> ... requires` form) and the primary keeps every
// instance. A genuine second primary is still a redefinition.
pub struct <T> Store { pub var value: T }
pub struct <P> Store<P> requires sizeof P <= 8 { pub var ptr: P }
pub struct <Q> Store<Q> { pub var q: Q }
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error
// DIAG: partial_spec_requires.k:10:5: error [SC001E]: a partial specialization selected by 'requires' is not supported yet; the primary is used for every instance
// DIAG: partial_spec_requires.k:11:5: error [R029E]: redefinition of 'Store'
