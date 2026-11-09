// --- lit wiring -----------------------------------------------------------
// An f80 hole type-checks on x86_64: fmt_buf.k declares FmtBuf::put_f80 there
// (`eval if` on x87), so no SC081E and no error. Running it, and the P003E a
// non-x87 target gives, are Tests/Codegen/fmt_f80_guard.k.
// REQUIRES: sysroot-x86_64-linux-gnu
// RUN: %kairo %s --target=x86_64-linux-gnu --type-check-only 2>&1 | %FileCheck %s --allow-empty --check-prefix=DIAG
// DIAG-NOT: SC081E
// DIAG-NOT: error

fn show() -> string {
    var x: f80 = 1.5
    return f"{x}"
}