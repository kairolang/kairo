// The explicit `as usize` that the lossy-conversion hint asks for is
// accepted on a `u64&` result, and a `u64` target needs no cast at all.

ffi "c++" import "inputs/u64_ref_return.h"

fn main() -> i32 {
    var a: usize = get_u64_ref() as usize
    var b: u64 = get_u64_ref()
    return if (a == 3 && b == 3) => 0 else => 1
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='error [' --implicit-check-not='I003E'
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
