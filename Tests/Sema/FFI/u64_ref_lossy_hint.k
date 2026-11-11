// `u64&` (an imported C++ reference) to `usize` is the same lossy
// conversion as `u64` to `usize` (conversion-lattice: no implicit u64 ->
// usize), so it gets the same "needs an explicit 'as'" hint. The hint was
// chosen on the reference type itself, which has no builtin kind.

ffi "c++" import "Inputs/u64_ref_return.h"

fn main() -> i32 {
    var x: usize = get_u64_ref()
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: u64_ref_lossy_hint.k:9:20: error [SC028E]: cannot convert 'u64&' to 'usize'; the conversion may lose value and needs an explicit 'as'
