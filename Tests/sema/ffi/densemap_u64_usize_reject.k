// `DenseMap<u64, usize>` keeps typing its key and mapped value: assigning
// a string to an element and reading an element into a string are SC028E.

ffi "c++" import "llvm/ADT/DenseMap.h"

fn main() -> i32 {
    var m: llvm::DenseMap<u64, usize>
    m[5] = "x"
    var s: string = m[5]
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: densemap_u64_usize_reject.k:8:12: error [SC028E]: cannot convert 'string' to '{{u64|usize}}'
// CHECK: densemap_u64_usize_reject.k:9:21: error [SC028E]: cannot convert '{{u64|usize}}&' to 'string'
