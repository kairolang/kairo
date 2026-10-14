// --print-cpus lists the CPU names LLVM knows for --target and compiles
// nothing, so the list must follow the triple rather than the host.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-cpus --target=x86_64-linux-gnu | %FileCheck %s --check-prefix=X86
// X86: Available CPUs for target 'x86_64-linux-gnu':
// X86: haswell

// RUN: %kairo %s --print-cpus --target=aarch64-linux-gnu | %FileCheck %s --check-prefix=ARM
// ARM: Available CPUs for target 'aarch64-linux-gnu':
// ARM: cortex-a72
