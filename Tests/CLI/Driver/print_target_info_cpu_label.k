// --print-target-info labels the CPU "Default CPU" when none was asked for
// and "CPU" when --mcpu names it.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-target-info --target=x86_64-linux-gnu | %FileCheck %s --check-prefix=DEFAULT
// RUN: %kairo %s --print-target-info --target=x86_64-linux-gnu --mcpu=znver3 | %FileCheck %s --check-prefix=MCPU
// DEFAULT: Default CPU:     x86-64
// MCPU-NOT: Default CPU
// MCPU: CPU:             znver3
