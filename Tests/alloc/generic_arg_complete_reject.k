// A type named only as the allocator generic argument must conform to
// `Allocator`: a type with no `alloc` member is rejected at the argument by
// the bound, while `System` is accepted.
import builtin::base::alloc::*

class NotAlloc { var x: i32 = 0 }

fn main() -> i32 {
    var unsafe *ok = alloc_bytes<System>(8, 8)
    var unsafe *a = alloc_bytes<i32>(8, 8)
    var unsafe *b = alloc_bytes<NotAlloc>(8, 8)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="I003E"
// CHECK: generic_arg_complete_reject.k:10:21: error [SC162E]: 'i32' does not conform to 'Allocator': no member 'alloc' with the requirement's signature
// CHECK: generic_arg_complete_reject.k:11:21: error [SC162E]: 'NotAlloc' does not conform to 'Allocator': no member 'alloc' with the requirement's signature
