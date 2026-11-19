// sort, sort_unstable and binary_search on element types whose own `<=>`
// is not a strict weak order (random, intransitive, constant, mostly
// right): each comparison checks that both operands are element slots of
// the array or stack temporaries (or the merge scratch, for sort), the
// guard zones stay intact, the result is a permutation of the input, and
// no move-only element is lost, duplicated or read after a move. A
// comparator that keeps the partitions unbalanced can send a range to the
// introsort's heap sort fallback. W8 takes the block partition, W64 the plain
// one, WMo the per-element moves.

import inputs::slice_support::*
import inputs::wild_support::*
import std::io

inline fn wild_check(a: usize, b: usize) {
    in_bounds(a)
    in_bounds(b)
}

pub struct W8 {
    pub var k: u32
    pub var seq: u32
}

extend W8 impl Elem, Ord {
    static fn make(k: u64, id: u64) -> W8 {
        return W8 { k: k as u32, seq: id as u32 }
    }

    static fn has_id() -> bool {
        return true
    }

    fn key(const self) -> u64 {
        return self.k
    }

    fn id(const self) -> u64 {
        return self.seq
    }

    fn op == (const self, const o: Self) -> bool {
        return self.k == o.k
    }

    @no_warn(SC202W)
    fn op <=> (const self, const o: Self) -> Ordering {
        unsafe {
            wild_check(&self as unsafe *const u8 as usize, &o as unsafe *const u8 as usize)
        }

        return wild_order(self.k, o.k)
    }
}

pub struct W64 {
    pub var k: u64
    pub var seq: u64
    pub var pad: [u64; 6]
}

extend W64 impl Elem, Ord {
    static fn make(k: u64, id: u64) -> W64 {
        return W64 { k: k, seq: id, pad: [k, id, ~k, ~id, k ^ id, k + id] }
    }

    static fn has_id() -> bool {
        return true
    }

    fn key(const self) -> u64 {
        if self.pad[0] != self.k || self.pad[2] != ~self.k || self.pad[5] != self.k + self.seq {
            fail("torn W64", self.k, self.seq)
        }

        return self.k
    }

    fn id(const self) -> u64 {
        return self.seq
    }

    fn op == (const self, const o: Self) -> bool {
        return self.k == o.k
    }

    @no_warn(SC202W)
    fn op <=> (const self, const o: Self) -> Ordering {
        unsafe {
            wild_check(&self as unsafe *const u8 as usize, &o as unsafe *const u8 as usize)
        }

        return wild_order(self.key(), o.key())
    }
}

pub class WMo impl Elem, Ord {
    pub var m: Mo

    pub fn WMo(self, k: u64, seq: u64) {
        self.m = Mo(k, seq)
    }

    @move pub fn WMo(self, other: Self) = default

    pub static fn make(k: u64, id: u64) -> WMo {
        return WMo(k, id)
    }

    pub static fn has_id() -> bool {
        return true
    }

    pub fn key(const self) -> u64 {
        return self.m.key()
    }

    pub fn id(const self) -> u64 {
        return self.m.id()
    }

    pub fn op == (const self, const o: Self) -> bool {
        return self.key() == o.key()
    }

    @no_warn(SC202W)
    pub fn op <=> (const self, const o: Self) -> Ordering {
        unsafe {
            wild_check(&self as unsafe *const u8 as usize, &o as unsafe *const u8 as usize)
        }

        return wild_order(self.key(), o.key())
    }
}

fn <T impl Elem> one_run(r: *Rng, run: u64) requires T impl Ord {
    var n           = wild_size(r)
    var unsafe *blk = raw_array<T>(n + 2 * GUARD)
    var unsafe *a   = guarded_array<T>(blk, n)
    CMP_MODE  = rng_below(r, 6)
    CMP_STATE = rng_next(r) | 1
    var sum   = fill_pattern<T>(a, n, rng_below(r, PATTERNS) as u32, r)
    var s     = Slice<T>(a, n)
    var which = rng_below(r, 3)
    if which == 0 {
        s.sort_unstable()
    } else if which == 1 {
        OWN_SCRATCH = true
        s.sort()
        OWN_SCRATCH = false
    } else if n > 0 {
        unsafe {
            var probe = rng_below(r, n as u64) as usize
            var res   = s.binary_search(T::make(a[probe].key(), 0))
            if res.1 > n {
                fail("binary_search out of range", res.1 as u64, n as u64)
            }
        }
    }

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
    destroy_all<T>(a, n)
    raw_array_free<T>(blk, n + 2 * GUARD)
}

fn <T impl Elem> fuzz(seed: u64, runs: u64) requires T impl Ord {
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
    fuzz<W8>(201, runs)
    fuzz<W64>(202, runs)
    fuzz<WMo>(203, runs)
    check(MO_OBJECTS == 0, "Mo objects leaked or destroyed twice", MO_OBJECTS as u64, 0)
    io::println(f"runs {3 * runs}")
    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK: runs 12000
