// Build systems probe their C compiler with -dumpversion,
// -print-resource-dir and --print-libgcc-file-name, with no input. kcc
// answers them through clang's driver instead of "no input files".
fn main() -> i32 { return 0 }

// --- lit wiring ---
// REQUIRES: kcc
// RUN: %kcc -dumpversion | %FileCheck %s --check-prefix=VER
// RUN: %kcc -print-resource-dir | %FileCheck %s --check-prefix=RES
// RUN: %kcc --print-libgcc-file-name | %FileCheck %s --check-prefix=GCC
// VER: {{^[0-9]+\.[0-9]+}}
// RES: {{.*}}clang{{.*}}
// GCC: {{.*}}libgcc{{.*}}
