// --icf-mode picks the identical-code-folding level that --icf passes to the
// linker; an unknown level is rejected.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: bundled-sysroot
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --icf --icf-mode=all | %FileCheck %s --check-prefix=ALL
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --icf | %FileCheck %s --check-prefix=SAFE
// RUN: { %kairo %s --target=x86_64-linux-musl --print-ld-args --icf --icf-mode=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// ALL: --icf=all
// SAFE: --icf=safe
// BAD: unknown --icf-mode bogus; expected safe or all
