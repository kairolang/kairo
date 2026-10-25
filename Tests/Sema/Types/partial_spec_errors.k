// Sema/Types/partial_spec_errors.k
// NULLABLE.md G0: the specializations Sema refuses. Two partials that both
// match and neither more specialized (C++ [temp.class.order]) make the
// instance ambiguous, reported once at its first written mention, with both
// candidates; `Pair<f64, f64>` is not ambiguous, `<W> Pair<W, W>` alone
// matches it. A partial selected by a `requires` clause needs requires-
// dispatch, which is not built: refused at its declaration rather than
// selected by its pattern alone (which would ignore the clause).
pub struct <A, B> Pair { pub var a: A; pub var b: B }
pub struct <X> Pair<X, i32> { pub var left: X }
pub struct <Y> Pair<i32, Y> { pub var right: Y }
pub struct <W> Pair<W, W> { pub var same: W }
pub struct <Z> Pair<*Z, *Z> requires sizeof Z <= 8 { pub var both: Z }
fn main() -> i32 {
    var ok: Pair<f64, f64>
    var amb: Pair<i32, i32>
    var again: Pair<i32, i32>
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error
// DIAG: partial_spec_errors.k:13:5: error [SC001E]: a partial specialization selected by 'requires' is not supported yet; the primary is used for every instance
// DIAG-NEXT: partial_spec_errors.k:13:5: note [SC001N]: partial specializations are selected by their argument pattern alone
// DIAG: partial_spec_errors.k:16:14: error [SC001E]: ambiguous partial specializations of 'Pair' for these arguments
// DIAG-NEXT: partial_spec_errors.k:10:5: note [SC001N]: matches this partial specialization
// DIAG-NEXT: partial_spec_errors.k:11:5: note [SC001N]: and this one, and neither is more specialized than the other
