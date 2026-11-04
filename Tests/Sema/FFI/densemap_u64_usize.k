// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
//
// `DenseMap<u64, usize>`: key and mapped value are both `unsigned long` to
// C++. The usize argument alone claimed that canonical type, so the KEY came
// back usize as well and `m[k]` / `m.find(k)` with a u64 failed (G91, the
// migrated NullnessFlow.k / ParamPassInference.k / SemaDump.k). Two
// arguments of different Kairo types now null the claim, and the ordinary
// mapping answers for both.

// DIAG-NOT: error

ffi "c++" import "llvm/ADT/DenseMap.h"

fn main() -> i32 {
    var m: llvm::DenseMap<u64, usize>
    var n: u64 = 3
    m[5] = n
    var it = m.find(5)
    var k: u64 = it->first
    var v: u64 = it->second
    return 0
}
