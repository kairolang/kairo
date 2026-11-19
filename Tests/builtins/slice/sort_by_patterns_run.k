// sort_by and sort_by_key (the stable merge sort through a callback) on
// eight input patterns at sizes 0..64 and around powers of two: the result
// is sorted, is a permutation of the input, and keeps equal keys in input
// order. Elements: i32, u64, an 8-byte pair, a 64-byte struct that detects
// tearing, a move-only type that is not relocatable (its constructor and
// destructor check every move, and the live count returns to zero), and a
// move-only type that moves as bytes.

import inputs::slice_support::*
import std::io

fn <T impl Elem> run_case(n: usize, pat: u32, by_key: bool, r: *Rng) {
    var unsafe *a = raw_array<T>(n)
    var sum       = fill_pattern<T>(a, n, pat, r)
    var s         = Slice<T>(a, n)
    if by_key {
        s.sort_by_key(key_of<T>)
    } else {
        s.sort_by(cmp_by_key<T>)
    }

    verify<T>(a, n, sum, true, (pat as u64) * 10 + (by_key as u64))
    destroy_all<T>(a, n)
    raw_array_free<T>(a, n)
}

fn <T impl Elem> run_all(const name: string, max_log: u32) {
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
    run_all<i32>("i32", 16)
    run_all<u64>("u64", 14)
    run_all<Pair>("pair", 14)
    run_all<S64>("s64", 12)
    run_all<Mo>("mo", 12)
    check(MO_OBJECTS == 0, "Mo objects leaked or destroyed twice", MO_OBJECTS as u64, 0)
    run_all<MoT>("mot", 12)
    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK:      i32 1520
// CHECK-NEXT: u64 1424
// CHECK-NEXT: pair 1424
// CHECK-NEXT: s64 1328
// CHECK-NEXT: mo 1328
// CHECK-NEXT: mot 1328
