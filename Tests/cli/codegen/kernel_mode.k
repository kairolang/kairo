// --kernel-mode selects the kernel code model with a static relocation model, no
// red zone and no implicit floating point. SSE is switched off on x86 only.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --kernel-mode || true; } | %FileCheck %s --check-prefix=X86
// X86: -mcmodel=kernel -mrelocation-model static -disable-red-zone -no-implicit-float -target-feature -sse
// RUN: { %kairo %s --print-clang-args --target=aarch64-linux-gnu --kernel-mode || true; } | %FileCheck %s --check-prefix=ARM
// ARM: -mcmodel=kernel
// ARM: -disable-red-zone
// RUN: { %kairo %s --print-clang-args --target=aarch64-linux-gnu --kernel-mode || true; } | %FileCheck %s --check-prefix=ARMN
// ARMN-NOT: -target-feature -sse
