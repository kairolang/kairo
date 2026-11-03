// P353: a lexer warning is reported once. A file is tokenized more than once
// (the import scan, then the preprocessor walk), and each lex reported its
// diagnostics again: this octal escape printed S025W three times. The
// diagnostic engine now drops a repeat of a delivered diagnostic (same code,
// location and message); the generated block's implicit-check-not fails on a
// second copy.

fn f() {
    var t = "\033[0m"
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:9:14: warning [S025W]: octal escape '\033' is only valid in byte strings (b"..."); use '\u' for unicode codepoints
// END-GENERATED-CHECKS(DIAG)
