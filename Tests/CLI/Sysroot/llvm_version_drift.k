// The llvm_version a generated SYSROOT.toml records has two sources: the
// share tree's templates, written by Scripts/ship_sysroot_inputs.py, and,
// for roots staged from an installed SDK (Linker/Sysroot/Sdk.k), the LLVM
// the toolchain is built against (SysrootManifest::toolchain_llvm_version). The
// script's copies are kept by hand; this fails when a toolchain bump
// leaves them behind.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: shell
// RUN: python3 %S/Inputs/llvm_version_drift.py "$(dirname %kairo_bin)/clang" %S/../../../Scripts/ship_sysroot_inputs.py | %FileCheck %s
// CHECK: same {{[0-9]+\.[0-9]+\.[0-9]+}} ({{[1-9][0-9]*}} sites)
