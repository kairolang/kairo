// A pack element's conversions and interpolations are checked against the
// pack's bounds at the definition, as a plain parameter's are
// (opaque_param_ops.k): with no bound granting them they are the bound
// error naming the requirement, not SC027E / SC080E (P141). The bounded
// forms compile and run in Codegen/packs/bound_conversions.k. A `: type`
// parameter's are still rejected (generics.mdx, the `: type` regime).
fn <...T> casts(...args: T) {
    for arg in args { var s = arg as string }
}
fn <...T> formats(...args: T) -> string {
    var s = ""
    for arg in args { s = f"{arg}" }
    return s
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:8:31: error [R051E]: 'as string' on 'T' needs a bound that declares 'op as' returning 'string'
// DIAG-NEXT: {{.*}}:7:5: note [R051N]: 'T' is declared with no bound
// DIAG: {{.*}}:12:30: error [R051E]: formatting a 'T' needs a bound that declares 'fn repr(self) -> string' or 'op as' returning 'string'
// DIAG-NEXT: {{.*}}:10:5: note [R051N]: 'T' is declared with no bound
