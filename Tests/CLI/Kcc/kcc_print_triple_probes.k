// Compiler-rt's configure normalises its triple with
// `kcc --target=X -print-target-triple`, and kcc said "no input files".
// The rest of clang's no-input probes (-print-effective-triple,
// -dumpmachine, -print-search-dirs, -print-prog-name=, -print-file-name=,
// either dash spelling) take the same path as -dumpversion: clang's driver
// answers for kairo's target.
fn main() -> i32 { return 0 }

// --- lit wiring ---
// REQUIRES: kcc
// RUN: %kcc --target=aarch64-linux-musl -print-target-triple | %FileCheck %s --check-prefix=TRIPLE
// RUN: %kcc --target=aarch64-linux-musl --print-target-triple | %FileCheck %s --check-prefix=TRIPLE
// RUN: %kcc --target=aarch64-linux-musl -print-effective-triple | %FileCheck %s --check-prefix=TRIPLE
// RUN: %kcc --target=aarch64-linux-musl -dumpmachine | %FileCheck %s --check-prefix=TRIPLE
// RUN: %kcc -print-search-dirs | %FileCheck %s --check-prefix=DIRS
// RUN: %kcc -print-prog-name=ld | %FileCheck %s --check-prefix=PROG
// RUN: %kcc -print-file-name=kairo-no-such-file.a | %FileCheck %s --check-prefix=FILE
// TRIPLE: {{^}}aarch64-unknown-linux-musl{{$}}
// DIRS: programs: ={{.*}}
// DIRS: libraries: ={{.*}}
// PROG: {{.*}}ld{{$}}
// FILE: {{^}}kairo-no-such-file.a{{$}}
