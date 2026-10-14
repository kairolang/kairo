// --march goes through clang's DRIVER (cc1 has no -march): the probe turns it into
// -target-cpu and the -target-feature pairs the extensions imply. --mcpu is pushed
// after the probe, so it wins as the last -target-cpu.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --march=x86-64-v3 || true; } | %FileCheck %s --check-prefix=MARCH
// MARCH: -target-cpu x86-64-v3
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --march=x86-64-v3 --mcpu=znver3 || true; } | %FileCheck %s --check-prefix=BOTH
// BOTH: -target-cpu x86-64-v3
// BOTH: -target-cpu znver3
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEF
// DEF: -target-cpu x86-64
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -target-cpu x86-64-v3
