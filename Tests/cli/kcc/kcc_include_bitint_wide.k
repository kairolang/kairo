// A C++ input that includes Kairo declaring i256 / u512 compiles for a target
// whose clang caps _BitInt at 128 bits by default (AArch64): the C++ line
// gets Kairo's 512-bit cap, so the declarations are the _BitInt types the
// Kairo objects were compiled with. The same holds for a header
// --emit-headers wrote. A target whose default cap is wider (x86_64) keeps
// clang's own.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot, sysroot-aarch64-linux-musl
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc --target=aarch64-linux-musl -c %S/inputs/bitint_wide/use.cc -o %t.d/a64.o
// RUN: %kcc --target=aarch64-linux-musl -### -c %S/inputs/bitint_wide/use.cc -o %t.d/a64.o 2>&1 | %FileCheck %s --check-prefix=A64
// A64: -main-file-name use.cc {{.*}}-fexperimental-max-bitint-width=512

// The emitted header, compiled by the same driver.
// RUN: (cd %S/inputs/bitint_wide && %kairo wide.k --target=aarch64-linux-musl --type-check-only --emit-headers %t.d/h)
// RUN: %kcc --target=aarch64-linux-musl -DUSE_HEADER -I %t.d/h -c %S/inputs/bitint_wide/use.cc -o %t.d/a64h.o

// RUN: %if sysroot-x86_64-linux-musl %{ %kcc --target=x86_64-linux-musl -### -c %S/inputs/bitint_wide/use.cc -o %t.d/x86.o 2>&1 | %FileCheck %s --check-prefix=X86 %}
// X86: -main-file-name use.cc
// X86-NOT: max-bitint-width

// The host program links and runs: C++ and Kairo agree on the values.
// RUN: %kcc %S/inputs/bitint_wide/use.cc -o %t.d/host.exe
// RUN: %t.d/host.exe
