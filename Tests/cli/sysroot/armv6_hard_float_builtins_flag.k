// The runtimes template's fixups give armv6 hard-float compiler-rt builtins
// -DCOMPILER_RT_ARMHF_TARGET (once, in the C and the assembly flags):
// compiler-rt's CMake defines it only for the arches it lists, and without
// it every builtin returning float or double hands it back in core registers
// while a hard-float caller reads s0/d0. A soft-float armv6 target and
// armv7 hard-float (which CMake already covers) are not touched.
//
// Not covered here: building armv6-linux-musl from the real share and running
// its validation programs under qemu-arm (tfbf.k exits 1), which needs the
// runtimes sources and an emulator.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: shell
// RUN: python3 %S/inputs/armv6_hf_fixup.py %S/../../../Scripts | %FileCheck %s
// CHECK: armv6-hard fixups 1 c 1 asm 1
// CHECK: armv6-soft fixups 0 c 0 asm 0
// CHECK: armv7-hard fixups 0 c 0 asm 0
