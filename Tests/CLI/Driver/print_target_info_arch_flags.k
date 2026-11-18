// --print-target-info describes the target a compile with the same flags
// uses: --m32 / --m64 switch the triple's architecture (and with it the
// pointer width and data layout), and the CPU line is the -target-cpu of
// the cc1 line --print-clang-args shows (--mcpu, --march, else clang's
// default for the triple), not LLVM's generic CPU.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-target-info --target=x86_64-linux-gnu --m32 | %FileCheck %s --check-prefix=M32
// M32: Triple:          i386-unknown-linux-gnu
// M32: Pointer width:   32-bit
// M32: Data layout:     e-m:e-p:32:32
// M32: Default CPU:     pentium4

// RUN: %kairo %s --print-clang-args --target=x86_64-linux-gnu --m32 | %FileCheck %s --check-prefix=M32CC1
// M32CC1: -triple i386-unknown-linux-gnu {{.*}}-target-cpu pentium4

// RUN: %kairo %s --print-target-info --target=i686-linux-gnu --m64 | %FileCheck %s --check-prefix=M64
// M64: Triple:          x86_64-unknown-linux-gnu
// M64: Pointer width:   64-bit
// M64: Default CPU:     x86-64

// --m32 wins over --m64, for the query as for a compile.
// RUN: %kairo %s --print-target-info --target=x86_64-linux-gnu --m64 --m32 | %FileCheck %s --check-prefix=M32

// RUN: %kairo %s --print-target-info --target=x86_64-linux-gnu --mcpu=znver3 | %FileCheck %s --check-prefix=MCPU
// MCPU: CPU:             znver3

// RUN: %kairo %s --print-target-info --target=x86_64-linux-gnu --march=x86-64-v3 | %FileCheck %s --check-prefix=MARCH
// MARCH: Default CPU:     x86-64-v3

// RUN: %kairo %s --print-target-info --target=aarch64-linux-gnu | %FileCheck %s --check-prefix=A64
// A64: Default CPU:     generic
