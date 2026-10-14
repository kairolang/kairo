// --dll is an alias for --shared on every target. On a Windows target it
// switches the linker to a DLL: --shared and the DllMainCRTStartup entry.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: bundled-sysroot
// RUN: %kairo %s --target=x86_64-windows-gnu --print-ld-args --dll | %FileCheck %s
// CHECK: --shared
// CHECK: DllMainCRTStartup
