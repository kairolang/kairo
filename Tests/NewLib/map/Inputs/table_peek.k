// Reads the block behind a HashMap or HashSet from outside the library, for
// the tests: the table's own check is not reachable from a user file, so
// this is an independent copy of its rules, written against the layout on a
// 64-bit target:
//   map / set  [block: *u8][len: usize]
//   block      [cap: usize][shift: u8][align_log2: u8][flags: u8][pad][seed: u64]
//              [slot: (hash32: u32, index: u32) x 2^(64 - shift)] ... entries
// An empty slot is all ones. Every function takes the container by pointer.

import std::io

pub const TP_EMPTY: u32 = 0xFFFFFFFF

pub fn <M> tp_block(m: *const M) -> unsafe *u8 {
    unsafe {
        return *(m as unsafe *const usize) as unsafe *u8
    }
}

pub fn <M> tp_len(m: *const M) -> usize {
    unsafe {
        return *((m as unsafe *const usize) + 1)
    }
}

pub fn <M> tp_cap(m: *const M) -> usize {
    unsafe {
        return *(tp_block(m) as unsafe *const usize)
    }
}

pub fn <M> tp_shift(m: *const M) -> u32 {
    unsafe {
        return *(tp_block(m) + 8)
    }
}

pub fn <M> tp_flags(m: *const M) -> u32 {
    unsafe {
        return *(tp_block(m) + 10)
    }
}

pub fn <M> tp_seed(m: *const M) -> u64 {
    unsafe {
        return *((tp_block(m) + 16) as unsafe *const u64)
    }
}

pub fn <M> tp_nslots(m: *const M) -> usize {
    return 1usize << (64 - tp_shift(m))
}

pub fn <M> tp_slot_hash(m: *const M, i: usize) -> u32 {
    unsafe {
        return *((tp_block(m) + 24 + i * 8) as unsafe *const u32)
    }
}

pub fn <M> tp_slot_index(m: *const M, i: usize) -> u32 {
    unsafe {
        return *((tp_block(m) + 24 + i * 8 + 4) as unsafe *const u32)
    }
}

pub fn <M> tp_home(m: *const M, hash32: u32) -> usize {
    return (hash32 >> (tp_shift(m) - 32)) as usize
}

/// The home slot of entry `e` (from its slot's cached hash bits), or
/// usize::MAX when no slot names it.
pub fn <M> tp_home_of(m: *const M, e: usize) -> usize {
    var i: usize = 0
    while i < tp_nslots(m) {
        if tp_slot_index(m, i) == e as u32 {
            return tp_home(m, tp_slot_hash(m, i))
        }

        i += 1
    }

    return usize::MAX
}

/// 0 when the structure is consistent, else the number of the first rule
/// that fails:
///   1  the slot count is a power of two within the limits
///   2  cap is nslots - nslots / 8 (0, with two slots, for an empty table)
///   3  len <= cap
///   4  an occupied slot names an entry index >= len
///   5  two slots name the same entry
///   6  the number of occupied slots is not len
///   7  a slot sits before its home, or an empty slot lies between its home
///      and it
pub fn <M> tp_check(m: *const M) -> u32 {
    var shift = tp_shift(m)
    if shift > 63 || shift < 32 {
        return 1
    }

    var n    = tp_nslots(m)
    var mask = n - 1
    var cap  = tp_cap(m)
    var len  = tp_len(m)
    if cap == 0 {
        if n != 2 {
            return 2
        }
    } else if n < 8 || cap != n - n / 8 {
        return 2
    }

    if len > cap {
        return 3
    }

    var seen: [bool]
    var k: usize = 0
    while k < len {
        seen.push(false)
        k += 1
    }

    var used:        usize = 0
    var first_empty: usize = usize::MAX
    var i:           usize = 0
    while i < n {
        var e = tp_slot_index(m, i)
        if e == TP_EMPTY {
            if first_empty == usize::MAX {
                first_empty = i
            }
        } else {
            if (e as usize) >= len {
                return 4
            }

            if seen[e as usize] {
                return 5
            }

            seen[e as usize] = true
            used += 1
        }

        i += 1
    }

    if used != len {
        return 6
    }

    var run:  usize = 0
    var step: usize = 1
    while step <= n {
        var j = (first_empty + step) & mask
        if tp_slot_index(m, j) == TP_EMPTY {
            run = 0
        } else {
            run += 1
            if ((j - tp_home(m, tp_slot_hash(m, j))) & mask) >= run {
                return 7
            }
        }

        step += 1
    }

    return 0
}

/// Prints a line and returns false when the table is inconsistent.
pub fn <M> tp_ok(m: *const M, const what: string) -> bool {
    var r = tp_check(m)
    if r != 0 {
        io::println(f"FAIL {what}: table rule {r}")
        return false
    }

    return true
}
