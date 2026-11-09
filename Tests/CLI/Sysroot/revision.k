// kairo --print-runtimes-revision and ksys --print-runtimes-revision print
// the LLVM runtimes revision the toolchain was built from (build.py embeds
// package_release.runtimes_revision()): the one share/kairo/runtimes/REVISION
// must equal (Compiler/Spec/SysRoot.md section 3). Both binaries carry the
// same string, and it is one line.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys
// RUN: %kairo --print-runtimes-revision > %t.kairo
// RUN: %ksys --print-runtimes-revision > %t.ksys
// RUN: diff %t.kairo %t.ksys
// RUN: test "$(wc -l < %t.kairo)" -eq 1
// RUN: %FileCheck %s < %t.kairo
// CHECK: {{^[0-9a-f]+(\+[0-9a-f]+)?$|^unknown$}}
