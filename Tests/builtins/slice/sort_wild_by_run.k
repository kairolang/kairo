// sort_by and partition_point driven by callbacks that are not strict weak
// orders (random, intransitive, constant, mostly right): no comparison is
// handed a pointer outside the array, its stack temporaries or its own
// scratch, the guard zones around the array are intact, the result is a
// permutation of the input, and no move-only element is lost, duplicated or
// read after a move.

import inputs::slice_support::*
import inputs::wild_support::*
import std::io

fn <T impl Elem> wild_cmp(a: *const T, b: *const T) -> Ordering {
    unsafe {
        in_bounds(a as unsafe *const u8 as usize)
        in_bounds(b as unsafe *const u8 as usize)
    }

    return wild_order(a->key(), b->key())
}

fn <T impl Elem> wild_pred(a: *const T) -> bool {
    unsafe {
        in_bounds(a as unsafe *const u8 as usize)
    }

    return wild_order(a->key(), 0) == Ordering::Less
}

fn <T impl Elem> one_run(r: *Rng, run: u64) {
    var n            = wild_size(r)
    var unsafe *blk  = raw_array<T>(n + 2 * GUARD)
    var unsafe *a    = guarded_array<T>(blk, n)
    CMP_MODE  = rng_below(r, 6)
    CMP_STATE = rng_next(r) | 1
    var sum = fill_pattern<T>(a, n, rng_below(r, PATTERNS) as u32, r)
    var s   = Slice<T>(a, n)
    OWN_SCRATCH = true
    s.sort_by(wild_cmp<T>)
    OWN_SCRATCH = false
    var got: u64 = 0
    var i: usize = 0
    unsafe {
        while i < n {
            got += tmix(a[i].key() ^ tmix(a[i].id()))
            i += 1
        }
    }

    if got != sum {
        fail("not a permutation of the input", run, n as u64)
    }

    guards_intact<T>(blk, n)
    eval if __builtin_is_same<T, Mo>() {
        if MO_OBJECTS != n as i64 {
            fail("Mo object count after sort", MO_OBJECTS as u64, n as u64)
        }
    }

    destroy_all<T>(a, n)
    raw_array_free<T>(blk, n + 2 * GUARD)
}

fn pp_run(r: *Rng) {
    var n           = wild_size(r)
    var unsafe *blk = raw_array<u64>(n + 2 * GUARD)
    var unsafe *a   = guarded_array<u64>(blk, n)
    CMP_MODE  = rng_below(r, 6)
    CMP_STATE = rng_next(r) | 1
    fill_pattern<u64>(a, n, rng_below(r, PATTERNS) as u32, r)
    var s  = Slice<u64>(a, n)
    var pp = s.partition_point(wild_pred<u64>)
    if pp > n {
        fail("partition_point out of range", pp as u64, n as u64)
    }

    guards_intact<u64>(blk, n)
    raw_array_free<u64>(blk, n + 2 * GUARD)
}

fn <T impl Elem> fuzz(seed: u64, runs: u64) {
    var r      = rng_make(seed)
    var i: u64 = 0
    while i < runs {
        one_run<T>(&r, i)
        i += 1
    }
}

fn main() -> i32 {
    var anchor: u64 = 0
    unsafe {
        mark_stack((&anchor) as unsafe *const u8 as usize)
    }

    var runs: u64 = 4000
    fuzz<u64>(101, runs)
    fuzz<S64>(102, runs)
    fuzz<Mo>(103, runs)
    fuzz<MoT>(105, runs)
    var r      = rng_make(106)
    var i: u64 = 0
    while i < runs {
        pp_run(&r)
        i += 1
    }

    check(MO_OBJECTS == 0, "Mo objects leaked or destroyed twice", MO_OBJECTS as u64, 0)
    io::println(f"runs {5 * runs}")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK: runs 20000
