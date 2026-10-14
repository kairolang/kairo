// The ELF linker line carries --eh-frame-hdr by default (unwinding needs the
// table); -fno-eh-frame-hdr drops it. Only visible in the ld args.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: bundled-sysroot
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args | %FileCheck %s --check-prefix=ON
// ON: --eh-frame-hdr
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args -fno-eh-frame-hdr | %FileCheck %s --check-prefix=OFF
// OFF-NOT: --eh-frame-hdr
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args -feh-frame-hdr | %FileCheck %s --check-prefix=ON
