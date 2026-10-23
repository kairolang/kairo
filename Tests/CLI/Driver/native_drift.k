// Drift guard between kairo's two clang lines. Kairo's own code compiles on
// a hand-built cc1 line whose target words come from a driver probe
// (ClangBackend::_driver_target_args); a C/C++ input compiles on the line
// clang's driver plans for it (Interop/Clang/ClangJobs.k). Different paths,
// one target: the triple, CPU, ABI and float ABI must agree, or the two kinds
// of object in one link disagree about the ABI. The triple is compared by
// architecture and environment: clang's driver normalizes its spelling
// (x86_64-linux-musl -> x86_64-unknown-linux-musl), kairo's line keeps the
// user's, and both name one target.
//
// --print-clang-args prints kairo's line, then each C/C++ input's.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl, sysroot-aarch64-linux-musl, sysroot-armv7-linux-musl, sysroot-x86_64-windows-gnu, sysroot-riscv64-linux-musl

// RUN: %kairo %S/Inputs/native_add.cc --print-clang-args --target=x86_64-linux-musl | %FileCheck %s --check-prefix=X64
// X64:      clang -cc1 -triple [[ARCH:[^- ]+]]-{{[^ ]*}}-[[ENV:[^- ]+]] {{.*}}-target-cpu [[CPU:[^ ]+]]
// X64-NEXT: clang -cc1 -triple [[ARCH]]-{{[^ ]*}}-[[ENV]] {{.*}}-target-cpu [[CPU]]

// RUN: %kairo %S/Inputs/native_add.cc --print-clang-args --target=aarch64-linux-musl | %FileCheck %s --check-prefix=A64
// A64:      clang -cc1 -triple [[ARCH:[^- ]+]]-{{[^ ]*}}-[[ENV:[^- ]+]] {{.*}}-target-cpu [[CPU:[^ ]+]] {{.*}}-target-abi [[ABI:[^ ]+]]
// A64-NEXT: clang -cc1 -triple [[ARCH]]-{{[^ ]*}}-[[ENV]] {{.*}}-target-cpu [[CPU]] {{.*}}-target-abi [[ABI]]

// RUN: %kairo %S/Inputs/native_add.cc --print-clang-args --target=armv7-linux-musl | %FileCheck %s --check-prefix=ARM
// ARM:      clang -cc1 -triple [[ARCH:[^- ]+]]-{{[^ ]*}}-[[ENV:[^- ]+]] {{.*}}-target-cpu [[CPU:[^ ]+]] {{.*}}-target-abi [[ABI:[^ ]+]] -mfloat-abi [[FA:[^ ]+]]
// ARM-NEXT: clang -cc1 -triple [[ARCH]]-{{[^ ]*}}-[[ENV]] {{.*}}-target-cpu [[CPU]] {{.*}}-target-abi [[ABI]] -mfloat-abi [[FA]]

// RUN: %kairo %S/Inputs/native_add.cc --print-clang-args --target=riscv64-linux-musl | %FileCheck %s --check-prefix=RV
// RV:      clang -cc1 -triple [[ARCH:[^- ]+]]-{{[^ ]*}}-[[ENV:[^- ]+]] {{.*}}-target-cpu [[CPU:[^ ]+]] {{.*}}-target-abi [[ABI:[^ ]+]]
// RV-NEXT: clang -cc1 -triple [[ARCH]]-{{[^ ]*}}-[[ENV]] {{.*}}-target-cpu [[CPU]] {{.*}}-target-abi [[ABI]]

// RUN: %kairo %S/Inputs/native_add.cc --print-clang-args --target=x86_64-windows-gnu | %FileCheck %s --check-prefix=MINGW
// MINGW:      clang -cc1 -triple [[ARCH:[^- ]+]]-{{[^ ]*}}-[[ENV:[^- ]+]] {{.*}}-target-cpu [[CPU:[^ ]+]]
// MINGW-NEXT: clang -cc1 -triple [[ARCH]]-{{[^ ]*}}-[[ENV]] {{.*}}-target-cpu [[CPU]]

// --march / --mcpu reach both lines.
// RUN: %kairo %S/Inputs/native_add.cc --print-clang-args --target=x86_64-linux-musl --mcpu=znver3 | %FileCheck %s --check-prefix=MCPU
// MCPU:      clang -cc1 {{.*}}-target-cpu znver3
// MCPU-NEXT: clang -cc1 {{.*}}-target-cpu znver3
