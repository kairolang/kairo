// --entry sets the ld entry symbol (-e), but only when the crt is not linked:
// with the crt the startup object owns the entry point, so the flag is inert.
// Pinned so the flag is not silently dropped, nor leaked into crt links.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --no-crt --entry=boot | %FileCheck %s --check-prefix=NOCRT
// NOCRT: ld.lld
// NOCRT: -e boot

// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args --entry=boot | %FileCheck %s --check-prefix=CRT
// CRT: ld.lld
// CRT-NOT: -e boot
