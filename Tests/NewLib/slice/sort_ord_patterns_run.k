// sort (the stable merge sort) and sort_unstable (the introsort) through
// the element's own `<=>`, on eight input patterns at sizes 0..64 and
// around powers of two up to 2^18: sorted, a permutation of the input, and
// for sort, equal keys in input order. The same element types as
// sort_by_patterns_run.k.

import Inputs::slice_support::*
import std::io

fn <T impl Elem> run_case(n: usize, pat: u32, stable: bool, r: *Rng) requires T impl Ord {
    var unsafe *a = raw_array<T>(n)
    var sum       = fill_pattern<T>(a, n, pat, r)
    var s         = Slice<T>(a, n)
    if stable {
        s.sort()
    } else {
        s.sort_unstable()
    }

    verify<T>(a, n, sum, stable, (pat as u64) * 10 + (stable as u64))
    destroy_all<T>(a, n)
    raw_array_free<T>(a, n)
}

fn <T impl Elem> run_all(const name: string, max_log: u32) requires T impl Ord {
    var r            = rng_make(0xC0FFEE)
    var cases: u64   = 0
    var n:     usize = 0
    loop {
        var pat: u32 = 0
        while pat < PATTERNS {
            run_case<T>(n, pat, false, &r)
            run_case<T>(n, pat, true, &r)
            cases += 2
            pat += 1
        }

        n = next_size(n, max_log)
        if n == 0 {
            break
        }
    }

    io::println(f"{name} {cases}")
}

fn main() -> i32 {
    run_all<i32>("i32", 18)
    run_all<u64>("u64", 18)
    run_all<Pair>("pair", 16)
    run_all<S64>("s64", 14)
    run_all<Mo>("mo", 14)
    check(MO_OBJECTS == 0, "Mo objects leaked or destroyed twice", MO_OBJECTS as u64, 0)
    run_all<MoT>("mot", 14)
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK:      i32 1616
// CHECK-NEXT: u64 1616
// CHECK-NEXT: pair 1520
// CHECK-NEXT: s64 1424
// CHECK-NEXT: mo 1424
// CHECK-NEXT: mot 1424
