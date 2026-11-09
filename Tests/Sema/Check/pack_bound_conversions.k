// A pack element's conversions are checked against the pack's bounds at
// the definition, as a plain parameter's are (opaque_param_ops.k): with no
// bound granting them they are the bound error naming the requirement, not
// SC027E. An interpolation with no bound granting a string is
// formatted per instance instead (decided 2026-11-03, FormatHole::deferred), so
// `formats` is clean; only a format spec on it is refused (SC080E). The
// bounded forms compile and run in Codegen/packs/bound_conversions.k.
fn <...T> casts(...args: T) {
    for arg in args { var s = arg as string }
}
fn <...T> formats(...args: T) -> string {
    var s = ""
    for arg in args { s = f"{arg}" }
    return s
}
fn <...T> formats_spec(...args: T) -> string {
    var s = ""
    for arg in args { s = f"{arg:>4}" }
    return s
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:9:31: error [R051E]: 'as string' on 'T' needs a bound that declares 'op as' returning 'string'
// DIAG-NEXT: {{.*}}:8:5: note [R051N]: 'T' is declared with no bound
// DIAG: {{.*}}:18:30: error [SC080E]: a format spec on a value whose type is generic is not supported yet
