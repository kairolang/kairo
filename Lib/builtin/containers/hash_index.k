/// --- The Kairo Project ---------- Lib/builtin/containers/hash_index.k --- ///
///
///   \brief The open-addressing index HashMap and HashSet share: the slot
///          table over a dense, insertion-ordered entry array.
///
///   \detail
///     The layout is CPython's compact dict / Rust's indexmap: the entries
///     live densely, in insertion order, in one array; a separate table of
///     8-byte SLOTS maps a hash to an entry index. A slot is
///
///         bits 63..32   tag: the key's hash, mixed (`tag_of`)
///         bits 31..0    entry index + 1; 0 is an empty slot
///
///     so a probe compares the tag before it touches an entry (a hit costs
///     one entry read, a miss almost never any), and a rebuild re-places
///     every slot from its tag alone, without hashing a key again.
///
///     The table has 2 * cap slots (cap, the entry capacity, is a power of
///     two, 8 or more), so it is never more than half full: linear probing,
///     home slot `tag >> shift` (the tag's top bits), and deletion by
///     backward shift (no tombstones; a probe sequence never grows with
///     erases). Entries and slots are one allocation: slots first, entries
///     after them (2 * cap * 8 bytes in, so aligned for any entry up to 128).
///
///     `tag_of` is a Fibonacci multiply of the key's hash: the high 32 bits
///     of h * 2^64/phi. It makes the table immune to a weak `hash` -- a
///     pointer's address, libc++'s identity `std::hash<int>`, a user's sum
///     of fields -- for one `imul`.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import base::intrinsics::*
import base::alloc::*

/// Not an entry index: what a miss returns.
pub eval HASH_NPOS: usize = ~0usize

/// The smallest entry capacity a table is made with.
pub eval HASH_MIN_CAP: usize = 8

/// The slot tag of a hash: its Fibonacci product's high 32 bits.
pub inline fn tag_of(h: usize) -> u32 {
    return (((h as u64) * 0x9e3779b97f4a7c15u64) >> 32) as u32
}

/// The slot word for tag t and entry index e.
pub inline fn slot_word(t: u32, e: usize) -> u64 { return ((t as u64) << 32) | ((e as u64) + 1) }

/// The entry index a non-empty slot word names.
pub inline fn slot_entry(s: u64) -> usize { return ((s as u32) - 1) as usize }

/// The tag a slot word carries.
pub inline fn slot_tag(s: u64) -> u32 { return (s >> 32) as u32 }

/// log2 of a power of two.
inline fn log2_pow2(n: usize) -> u32 { return __builtin_ctz(n) }

/// The home-slot shift for a table of `nslots` (a power of two): the tag's
/// top log2(nslots) bits are the home.
pub inline fn shift_for(nslots: usize) -> u32 { return 32 - log2_pow2(nslots) }

/// Bytes of a table of entry capacity `cap` whose entries are `esize` bytes:
/// 2 * cap slots, then the entries. Traps on overflow.
pub inline fn block_bytes(cap: usize, esize: usize) -> usize {
    var e: usize = 0
    if __builtin_mul_overflow(cap, esize, &e) { __builtin_trap() }
    var s = cap * 16
    if (s / 16) != cap { __builtin_trap() }
    var t: usize = 0
    if __builtin_add_overflow(s, e, &t) { __builtin_trap() }
    return t
}

/// The block's alignment: a slot's, or the entry's if larger.
pub inline fn block_align(ealign: usize) -> usize { return (if ealign > 8 => ealign else => 8usize) }

/// A table block from the allocator in effect, its slots zeroed; runs the
/// OOM hook on failure.
pub fn block_alloc(cap: usize, esize: usize, ealign: usize) -> unsafe *u8 {
    var bytes = block_bytes(cap, esize)
    var align = block_align(ealign)
    var unsafe *b = alloc_raw(bytes, align)
    @unlikely if b == &null { oom(bytes, align) }
    unsafe { __builtin_set_mem(b, 0 as byte, cap * 16) }
    return b
}

/// Gives a block back to the allocator it came from.
pub inline fn block_free(b: unsafe *u8, cap: usize, esize: usize, ealign: usize) {
    if cap == 0 { return }
    free_raw(b, block_bytes(cap, esize), block_align(ealign))
}

/// What an empty table's block is: no allocation, but a non-null pointer
/// aligned for the entries, so `block_entries(b, 0)` is a valid empty array.
pub inline fn block_empty(ealign: usize) -> unsafe *u8 { return dangling(block_align(ealign)) }

/// The slots of a block, and its entries.
pub inline fn block_slots(b: unsafe *u8) -> unsafe *u64 { unsafe { return b as unsafe *u64 } }
pub inline fn block_entries(b: unsafe *u8, cap: usize) -> unsafe *u8 { unsafe { return b + cap * 16 } }

/// The first empty slot of k's probe sequence from tag t: where a new key
/// with that tag goes. The table is never full.
pub inline fn empty_slot(slots: unsafe *u64, mask: usize, shift: u32, t: u32) -> usize {
    var i = (t >> shift) as usize
    unsafe { while slots[i] != 0 { i = (i + 1) & mask } }
    return i
}

/// Copies every occupied slot of `old` into the zeroed `slots` at its home
/// in the new geometry. Indices are unchanged: the entries keep their places.
pub fn rebuild(slots: unsafe *u64, mask: usize, shift: u32, old: unsafe *u64, old_n: usize) {
    var i: usize = 0
    unsafe {
        while i < old_n {
            var s = old[i]
            if s != 0 { slots[empty_slot(slots, mask, shift, slot_tag(s))] = s }
            i += 1
        }
    }
}

/// The slot holding entry index e, whose tag is t. It is there.
pub inline fn slot_of_entry(slots: unsafe *u64, mask: usize, shift: u32, t: u32, e: usize) -> usize {
    var want = slot_word(t, e)
    var i = (t >> shift) as usize
    unsafe { while slots[i] != want { i = (i + 1) & mask } }
    return i
}

/// Empties slot i and closes the gap: every later slot of the same cluster
/// whose home is not cyclically in (i, k] moves back into it (backward-shift
/// deletion), so no probe ever needs a tombstone.
pub fn remove_slot(slots: unsafe *u64, mask: usize, shift: u32, i: usize) {
    var hole = i
    var k = (i + 1) & mask
    unsafe {
        while true {
            var s = slots[k]
            if s == 0 { break }
            var home = (slot_tag(s) >> shift) as usize
            if ((k - home) & mask) >= ((k - hole) & mask) {
                slots[hole] = s
                hole = k
            }
            k = (k + 1) & mask
        }
        slots[hole] = 0
    }
}

/// After the entries above index e moved down by one (an order-keeping
/// erase): every slot naming an index past e names one less.
pub fn shift_down_after(slots: unsafe *u64, nslots: usize, e: usize) {
    var i: usize = 0
    var lim = (e as u64) + 1
    unsafe {
        while i < nslots {
            var s = slots[i]
            if (s != 0) && ((s & 0xffffffffu64) > lim) { slots[i] = s - 1 }
            i += 1
        }
    }
}

/// The entry capacity to grow to from cap so that `want` entries fit.
pub inline fn grown_cap(cap: usize, want: usize) -> usize {
    var c = (if cap == 0 => HASH_MIN_CAP else => cap * 2)
    while c < want { c *= 2 }
    // Indices are 32 bits in a slot.
    if c > 0x80000000usize { __builtin_trap() }
    return c
}

/// Moves the entry at src to the uninitialized dst, leaving src's storage
/// uninitialized: bytes when the entry is trivially relocatable, else a copy
/// and the source destroyed (a COPY class has no move constructor to use).
pub inline fn <E> relocate_entry(dst: unsafe *u8, src: unsafe *E) {
    if __builtin_is_trivially_relocatable<E>() {
        unsafe { __builtin_copy(dst, src as unsafe *u8, sizeof E) }
        return
    }
    unsafe {
        __builtin_construct_at<E>(dst, *src)
        __builtin_destruct_at(src as *E)
    }
}
