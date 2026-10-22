// -frelro / -fno-relro are a tri-state on the ELF linker line: unset emits
// nothing, on emits `-z relro`, off emits `-z norelro`.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args | %FileCheck %s --check-prefix=UNSET
// UNSET-NOT: {{[ /]relro|norelro}}
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args -frelro | %FileCheck %s --check-prefix=ON
// ON: -z relro
// ON-NOT: norelro
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args -fno-relro | %FileCheck %s --check-prefix=OFF
// OFF: -z norelro
