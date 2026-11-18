// Only `f`, `r`, `fr` and `rf` (any case) touching a quote are a string
// prefix. `R_99E` hashes to the same 32-bit value as `r`; a longer name is
// a name whatever its hash, so the string after it is an ordinary string,
// whose `\q` is an unknown escape.

fn f() {
    var R_99E = 1
    var s     = R_99E"\q"
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:8:23: error [S033E]: unknown escape sequence '\q'
// DIAG: {{.*}}:8:22: error [S063E]: unexpected token found where 'string' expected
// END-GENERATED-CHECKS(DIAG)
