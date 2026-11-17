// Comparators that are not strict weak orders, and the bounds they are
// checked against: every pointer a comparison is handed must be an element
// slot of the array under test, or lie in the caller's stack (the sorts'
// one-element temporaries), or anywhere once OWN_SCRATCH is set (a sort that
// allocates its own scratch, whose address is not known here). Guard zones
// around the array catch a stray write. Not a test.

import Inputs::slice_support::*

pub static ARR_LO: usize = 0
pub static ARR_HI: usize = 0
pub static STK_LO: usize = 0
pub static STK_HI: usize = 0
pub static ELEM_SIZE: usize = 1
pub static CMP_MODE: u64 = 0
pub static CMP_STATE: u64 = 1
pub static CMP_CALLS: u64 = 0
pub static OWN_SCRATCH: bool = false

pub eval GUARD: usize = 4
pub eval GUARD_BYTE: u8 = 0xA5

/// Marks the current stack, from the caller's frame down 4 MiB.
pub fn mark_stack(anchor: usize) {
    STK_HI = anchor + 4096
    STK_LO = STK_HI - (4usize << 20)
}

pub fn in_bounds(p: usize) {
    if p >= ARR_LO && p < ARR_HI {
        if (p - ARR_LO) % ELEM_SIZE != 0 {
            fail("comparator pointer splits an element", p as u64, ARR_LO as u64)
        }

        return
    }

    if p >= STK_LO && p < STK_HI {
        return
    }

    if OWN_SCRATCH {
        return
    }

    fail("comparator pointer out of bounds", p as u64, ARR_LO as u64)
}

/// The answer of a comparator in mode CMP_MODE: random, consistent per pair
/// but not transitive, constant (three ways), or the true order wrong one
/// time in eight.
pub fn wild_order(ka: u64, kb: u64) -> Ordering {
    CMP_CALLS += 1
    var x = CMP_STATE
    x ^= x >> 12
    x ^= x << 25
    x ^= x >> 27
    CMP_STATE = x
    var m    = CMP_MODE
    var pick = x % 3
    if m == 1 {
        pick = tmix(ka * 31 + kb) % 3
    }

    if m == 2 {
        pick = 0
    }

    if m == 3 {
        pick = 2
    }

    if m == 4 {
        pick = 1
    }

    if m == 5 {
        pick = (if ka < kb => 0u64 else => (if ka > kb => 2u64 else => 1u64))
        if (x >> 40) % 8 == 0 {
            pick = (x >> 50) % 3
        }
    }

    if pick == 0 {
        return Ordering::Less
    }

    if pick == 1 {
        return Ordering::Equal
    }

    return Ordering::Greater
}

pub fn guard_fill(p: unsafe *u8, bytes: usize) {
    unsafe {
        __builtin_set_mem(p, GUARD_BYTE as byte, bytes)
    }
}

pub fn guard_check(p: unsafe *u8, bytes: usize, what: u64) {
    var i: usize = 0
    unsafe {
        while i < bytes {
            if p[i] != GUARD_BYTE {
                fail("guard zone overwritten", what, i as u64)
            }

            i += 1
        }
    }
}

/// A run length: mostly short, sometimes long enough for the block
/// partition and several merge levels.
pub fn wild_size(r: *Rng) -> usize {
    var shape = rng_below(r, 100)
    if shape < 70 {
        return rng_below(r, 65) as usize
    }

    if shape < 95 {
        return 65 + rng_below(r, 536) as usize
    }

    return 601 + rng_below(r, 4400) as usize
}

/// Storage for `n` elements between two guard zones; sets ARR_LO / ARR_HI.
/// Returns the first element.
pub fn <T> guarded_array(block: unsafe *T, n: usize) -> unsafe *T {
    unsafe {
        var unsafe *a = block + GUARD
        guard_fill(block as unsafe *u8, GUARD * sizeof T)
        guard_fill((a + n) as unsafe *u8, GUARD * sizeof T)
        ARR_LO    = a as unsafe *u8 as usize
        ARR_HI    = ARR_LO + n * sizeof T
        ELEM_SIZE = sizeof T
        return a
    }
}

pub fn <T> guards_intact(block: unsafe *T, n: usize) {
    unsafe {
        guard_check(block as unsafe *u8, GUARD * sizeof T, 1)
        guard_check((block + GUARD + n) as unsafe *u8, GUARD * sizeof T, 2)
    }
}
