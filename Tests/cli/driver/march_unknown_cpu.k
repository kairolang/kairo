fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// On x86 --march names a CPU, so an unknown one is P006E before the driver
// probe forwards it, as for --mcpu, and the backend start (I006F) is never
// reached. A real CPU passes.
// RUN: { %kairo %s --type-check-only --target=x86_64-unknown-linux-gnu --march=bogus 2>&1 || true; } | %FileCheck %s --implicit-check-not=I006F
// CHECK: error [P006E]: unknown target CPU 'bogus' given to --march for target 'x86_64-unknown-linux-gnu'
// CHECK: note [P006N]: on x86 --march names a CPU; run with --print-cpus --target=x86_64-unknown-linux-gnu to list valid values
// RUN: %kairo %s --type-check-only --target=x86_64-unknown-linux-gnu --march=haswell
