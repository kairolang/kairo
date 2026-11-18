// `for (k, *p) in m` over a const map is rejected by Kairo, not by the C++
// compiler: the iterable's `op in (const self)` yields pointers to const, so
// the binder has to be `const *p`, and a write through it is an error.

fn bad(const m: {i32: i32}) {
    for (k, *p) in m { *p = 0 }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: for_in_const_map_binder.k:6:13: error [SC298E]: the binder '*p' does not bind what 'op in (const self)' yields
// CHECK: fix-it:"{{.*}}for_in_const_map_binder.k":{6:13-6:15}:"const *p"
// CHECK: for_in_const_map_binder.k:6:24: error [SC071E]: cannot assign to '*p': 'p' points to const
