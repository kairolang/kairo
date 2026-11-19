// A HashMap declares no `op ==`, so two maps cannot be compared, whatever
// order their entries are in: the comparison is rejected at compile time
// (hash_map.k declares no equality; hash_set.k declares one that ignores
// order, tested in set_order.k). indexmap's `equality` property, where two
// maps with the same entries in any order are equal, has no counterpart.
//
// Cases from indexmap tests/quick.rs (equality)
// Cases from indexmap src/map/tests.rs (partial_eq_and_eq)

fn main() -> i32 {
    var a: {u64: u64} = {1: 1, 2: 2}
    var b: {u64: u64} = {2: 2, 1: 1}
    var same = a == b
    var other = a != b
    return 0
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s
// CHECK: no_map_equality.k:13:16: error [SC066E]: no 'op ==' on '{u64: u64}'
// CHECK: no_map_equality.k:14:17: error [SC066E]: no 'op ==' on '{u64: u64}'
