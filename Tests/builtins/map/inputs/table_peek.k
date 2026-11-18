// Reads the block behind a HashMap or HashSet from outside the library, for
// the tests: the table's own check is not reachable from a user file, so
// this is an independent copy of its rules, written against the layout on a
// 64-bit target:
//   map / set  [block: *u8][len: usize]
//   block      [cap][mask][room][ent][seed: u64][align_log2: u8][flags: u8] ... 64 bytes
//              [bucket x (mask + 1)]         64 bytes each:
//                 tag: u8 x 12               0xFF empty, 0x80 tombstone, else 7 hash bits
//                 filler: u8 x 4             0x80
//                 index: u32 x 12            the entry a full slot names
//              [hash: u32 x cap]             per entry: home bucket = hash & mask, tag = hash >> 25
//              ... entries at `ent`
// A probe sequence visits the home bucket, then buckets at triangular
// distances (1, 3, 6, ...), and ends at the first one with an empty slot.
// A slot is named `bucket * 16 + i`. Every function takes the container by
// pointer.

import std::io

pub const TP_EMPTY: u8 = 0xFF
pub const TP_DEAD: u8 = 0x80
pub const TP_SLOTS: usize = 12
pub const TP_BUCKET: usize = 64

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

pub fn <M> tp_word(m: *const M, i: usize) -> usize {
    unsafe {
        return *((tp_block(m) as unsafe *const usize) + i)
    }
}

pub fn <M> tp_cap(m: *const M) -> usize { return tp_word(m, 0) }
pub fn <M> tp_nbuckets(m: *const M) -> usize { return tp_word(m, 1) + 1 }
pub fn <M> tp_room(m: *const M) -> usize { return tp_word(m, 2) }
pub fn <M> tp_ent(m: *const M) -> usize { return tp_word(m, 3) }
pub fn <M> tp_seed(m: *const M) -> u64 { return tp_word(m, 4) as u64 }

pub fn <M> tp_flags(m: *const M) -> u32 {
    unsafe {
        return *(tp_block(m) + 41)
    }
}

/// Byte `i` (0..16: 12 tags, then the filler) of bucket `b`.
pub fn <M> tp_tag(m: *const M, b: usize, i: usize) -> u8 {
    unsafe {
        return *(tp_block(m) + TP_BUCKET + b * TP_BUCKET + i)
    }
}

pub fn <M> tp_slot_index(m: *const M, b: usize, i: usize) -> u32 {
    unsafe {
        return *((tp_block(m) + TP_BUCKET + b * TP_BUCKET + 16 + i * 4) as unsafe *const u32)
    }
}

/// The stored hash bits of entry `e`.
pub fn <M> tp_hash(m: *const M, e: usize) -> u32 {
    unsafe {
        return *((tp_block(m) + TP_BUCKET + tp_nbuckets(m) * TP_BUCKET + e * 4) as unsafe *const u32)
    }
}

/// The home bucket of entry `e`.
pub fn <M> tp_home_of(m: *const M, e: usize) -> usize {
    return (tp_hash(m, e) as usize) & (tp_nbuckets(m) - 1)
}

/// The bucket whose slot names entry `e`, or usize::MAX.
pub fn <M> tp_bucket_of(m: *const M, e: usize) -> usize {
    var b: usize = 0
    while b < tp_nbuckets(m) {
        var i: usize = 0
        while i < TP_SLOTS {
            if tp_tag(m, b, i) < TP_DEAD && tp_slot_index(m, b, i) == e as u32 {
                return b
            }

            i += 1
        }

        b += 1
    }

    return usize::MAX
}

pub fn <M> tp_tombstones(m: *const M) -> usize {
    var c: usize = 0
    var b: usize = 0
    while b < tp_nbuckets(m) {
        var i: usize = 0
        while i < TP_SLOTS {
            if tp_tag(m, b, i) == TP_DEAD {
                c += 1
            }

            i += 1
        }

        b += 1
    }

    return c
}

/// True when one of the slots of bucket `b` is empty.
fn <M> tp_bucket_has_empty(m: *const M, b: usize) -> bool {
    var i: usize = 0
    while i < TP_SLOTS {
        if tp_tag(m, b, i) == TP_EMPTY {
            return true
        }

        i += 1
    }

    return false
}

/// 0 when the structure is consistent, else the number of the first rule
/// that fails:
///    1  the bucket count is a power of two
///    2  cap is 8 * nbuckets (an empty table: one bucket, cap 0, no room)
///    3  len <= cap
///    4  a bucket's four filler bytes are not the tombstone value
///    5  a tag is none of empty, tombstone, 7 hash bits
///    6  a full slot names an entry index >= len
///    7  two slots name the same entry
///    8  a full slot's tag is not the tag of its entry's stored hash
///    9  the number of full slots is not len
///   10  room is not cap - len - tombstones
///   11  an entry is not reachable: a bucket with an empty slot comes
///       before its bucket on the probe sequence from its home
pub fn <M> tp_check(m: *const M) -> u32 {
    var n    = tp_nbuckets(m)
    var mask = n - 1
    var cap  = tp_cap(m)
    var len  = tp_len(m)
    if (n & mask) != 0 {
        return 1
    }

    if cap == 0 {
        if n != 1 || tp_room(m) != 0 {
            return 2
        }

        if len != 0 {
            return 3
        }

        var j: usize = 0
        while j < TP_SLOTS {
            if tp_tag(m, 0, j) != TP_EMPTY {
                return 5
            }

            j += 1
        }

        return 0
    }

    if cap != n * 8 || tp_ent(m) < TP_BUCKET + n * TP_BUCKET + cap * 4 {
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

    // mark[b]: 1 + the home whose probe sequence was last walked over b.
    var mark: [usize]
    k = 0
    while k < n {
        mark.push(0)
        k += 1
    }

    var full: usize = 0
    var dead: usize = 0
    var b:    usize = 0
    while b < n {
        var f: usize = TP_SLOTS
        while f < 16 {
            if tp_tag(m, b, f) != TP_DEAD {
                return 4
            }

            f += 1
        }

        var i: usize = 0
        while i < TP_SLOTS {
            var t = tp_tag(m, b, i)
            if t == TP_DEAD {
                dead += 1
            } else if t != TP_EMPTY {
                if t > TP_DEAD {
                    return 5
                }

                var e = tp_slot_index(m, b, i) as usize
                if e >= len {
                    return 6
                }

                if seen[e] {
                    return 7
                }

                if t != (tp_hash(m, e) >> 25) as u8 {
                    return 8
                }

                seen[e] = true
                full += 1
                var home = (tp_hash(m, e) as usize) & mask
                if mark[b] != home + 1 {
                    var at          = home
                    var step: usize = 0
                    loop {
                        mark[at] = home + 1
                        if tp_bucket_has_empty(m, at) || step > n {
                            break
                        }

                        step += 1
                        at = (at + step) & mask
                    }

                    if mark[b] != home + 1 {
                        return 11
                    }
                }
            }

            i += 1
        }

        b += 1
    }

    if full != len {
        return 9
    }

    if len + dead > cap || tp_room(m) != cap - len - dead {
        return 10
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
