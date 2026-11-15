// An escape's digits are ASCII bytes, and `\X` is no escape. A non-ASCII
// character after `\x` or `\u` is not a digit: it ends the run, and the
// escape is short. `\X41` is an unknown escape in the lexer, as it is in
// every decoder of literal text, instead of reaching lowering undecoded.

fn f() {
    var upper_x  = "\X41"
    var x_utf8   = "\xŁ1"
    var u_utf8   = "\uŁ041"
    var chr_utf8 = '\xŁ1'
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:7:21: error [S033E]: unknown escape sequence '\X'
// DIAG: {{.*}}:8:21: error [S023E]: invalid '\x' hex escape '\x': expected exactly 2 hex digits (0-9, a-f, A-F)
// DIAG: {{.*}}:9:21: error [S028E]: invalid '\u' unicode escape '\u': expected exactly 4 hex digits (0-9, a-f, A-F)
// DIAG: {{.*}}:10:21: error [S023E]: invalid '\x' hex escape '\x': expected exactly 2 hex digits (0-9, a-f, A-F)
// DIAG: {{.*}}:7:20: error [S063E]: unexpected token found where 'string' expected
// DIAG: {{.*}}:8:20: error [S063E]: unexpected token found where 'string' expected
// DIAG: {{.*}}:9:20: error [S063E]: unexpected token found where 'string' expected
// DIAG: {{.*}}:10:20: error [S063E]: unexpected token found where 'string' expected
// END-GENERATED-CHECKS(DIAG)
