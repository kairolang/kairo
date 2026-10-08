// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --target i386-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only -fno-implicit-conv 2>&1 || true; } | %FileCheck %s --check-prefix=NOIMP
//
// What the boundary rung (Conversion::abi_widen) must still refuse. usize
// is [32, 64] wide across 32/64-bit targets, so anything that narrows on
// SOME of them is refused on all: usize -> u32, u64 -> usize, and u32 -> isize
// (equal widths on a 32-bit target). Signed -> unsigned never widens.
// Kairo-to-Kairo calls are the lattice's alone (§4). Under
// -fno-implicit-conv the rung is off like every other W.

ffi "c++" import "abi_widen.h"

fn kairo_size(n: usize) {}

fn refuse(c: u32, f: i32, n: usize, s: isize, w: u64) {
    take_u32(n)
    take_i32(s)
    take_size(f)
    take_diff(n)
    take_size(w)
    take_diff(c)
    kairo_size(c)
}

fn gated(c: u32) {
    take_size(c)
}

// DIAG:      abi_widen_errors.k:17:5: error [SC063E]: no matching overload for call to 'take_u32'
// DIAG:      note [I900N]: candidate not viable: cannot convert argument of type 'usize' to parameter 'n' of type 'u32'
// DIAG:      abi_widen_errors.k:18:5: error [SC063E]: no matching overload for call to 'take_i32'
// DIAG:      note [I900N]: candidate not viable: cannot convert argument of type 'isize' to parameter 'n' of type 'i32'
// DIAG:      abi_widen_errors.k:19:5: error [SC063E]: no matching overload for call to 'take_size'
// DIAG:      note [I900N]: candidate not viable: cannot convert argument of type 'i32' to parameter 'n' of type 'usize'
// DIAG:      abi_widen_errors.k:20:5: error [SC063E]: no matching overload for call to 'take_diff'
// DIAG:      note [I900N]: candidate not viable: cannot convert argument of type 'usize' to parameter 'd' of type 'isize'
// DIAG:      abi_widen_errors.k:21:5: error [SC063E]: no matching overload for call to 'take_size'
// DIAG:      note [I900N]: candidate not viable: cannot convert argument of type 'u64' to parameter 'n' of type 'usize'
// DIAG:      abi_widen_errors.k:22:5: error [SC063E]: no matching overload for call to 'take_diff'
// DIAG:      note [I900N]: candidate not viable: cannot convert argument of type 'u32' to parameter 'd' of type 'isize'
// DIAG:      abi_widen_errors.k:23:5: error
// DIAG-NOT:  abi_widen_errors.k:27:{{[0-9]+}}: error

// NOIMP:     abi_widen_errors.k:27:5: error [SC063E]: no matching overload for call to 'take_size'
