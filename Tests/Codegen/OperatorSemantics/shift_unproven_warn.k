// OperatorSemantics: -Wshift-count-unproven names each shift whose count
// mask costs an instruction (SHIFT spec §5): ARM32 only, off by default, and
// never for a proven count.

ffi "c" fn shl(x: u32, n: u32) -> u32 = x << n
ffi "c" fn masked(x: u32, n: u32) -> u32 = x << (n & 31u32)
ffi "c" fn constant(x: u32) -> u32 = x << 4

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-armv7-linux-musl
// RUN: { %kairo %s --freestanding --target thumbv7m-none-eabi -Wshift-count-unproven -c -o %t.o 2>&1 || true; } | %FileCheck %s --check-prefix=ARM
// RUN: { %kairo %s --freestanding --target thumbv7m-none-eabi -c -o %t.off.o 2>&1 || true; } | %FileCheck %s --check-prefix=OFF --allow-empty
// RUN: { %kairo %s --freestanding --target aarch64-none-elf -Wshift-count-unproven -c -o %t.a64.o 2>&1 || true; } | %FileCheck %s --check-prefix=OFF --allow-empty
// A hosted build compiles the builtins too; only the user's shift warns.
// RUN: { %kairo %s --target armv7-linux-musleabihf -Wshift-count-unproven -c -o %t.h.o 2>&1 || true; } | %FileCheck %s --check-prefix=HOSTED --implicit-check-not=SC241W
// HOSTED: shift_unproven_warn.k:5:41: warning [SC241W]
// ARM: shift_unproven_warn.k:5:41: warning [SC241W]: shift count is not proven below the width of 'u32'; masking costs an instruction on this target
// ARM-NEXT: shift_unproven_warn.k:5:41: note [{{[A-Z0-9]+}}]: mask it yourself (n & 31) or bound it in a range loop to remove the cost
// ARM-NOT: warning
// OFF-NOT: SC241W
