// --build-id=<style> is passed to ld as --build-id=<style>; the default is
// fast. Checked via --print-ld-args, which links nothing.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl
// RUN: %kairo --target=x86_64-linux-musl --print-ld-args --build-id=sha1 %s | %FileCheck %s --check-prefix=SHA1
// SHA1: --build-id=sha1
// RUN: %kairo --target=x86_64-linux-musl --print-ld-args %s | %FileCheck %s --check-prefix=DEF
// DEF: --build-id=fast
