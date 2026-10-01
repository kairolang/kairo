// --- lit wiring -----------------------------------------------------------
// FIXME(CONST-EVAL-FOLD): put_f80 is out of the builtin root until it can be
// declared per target; until then an f80 hole is a clean SC081E, not a
// "missing FmtBuf" that reads like a broken install.
// REQUIRES: x86_64
// RUN: { %kairo %s --target=x86_64-linux-gnu --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: fstring_f80.k:3:{{[0-9]+}}: error [SC081E]: an 'f80' value cannot be formatted yet
// DIAG-NOT: FmtBuf

fn show() -> string {
    var x: f80 = 1.5
    return f"{x}"
}