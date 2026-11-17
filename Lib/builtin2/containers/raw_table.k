/// builtin/containers/raw_table.k

ffi "c++" import "rt/global_alloc.h"

import base::cmp::*
import base::copy::*
import base::hash::*
import base::intrinsics::*
import base::iter::*
import string::*

prot eval NO_ENTRY: usize = usize::MAX

/// The index holds 32-bit entry indices, and a slot's home is recoverable
/// from its 32 cached hash bits for at most 2^32 slots, which carry
/// `2^32 - 2^29` entries at full load: that is the real entry limit.
priv eval RT_MAX_SLOTS_LOG2: u32   = 32
priv eval RT_MAX_ENTRIES:    u64   = 0xFFFFFFFEu64
priv eval RT_MIN_SLOTS:      usize = 8

/// An insert that walks more slots than this while the index is under half
/// full asks the owner for a new seed.
priv eval RT_PROBE_LIMIT: usize = 128

priv eval RT_FLAG_RESEED_WANTED: u8 = 1
priv eval RT_FLAG_RESEEDED:      u8 = 2

/// An empty slot is all ones, so a fresh index is one fill and a slot's
/// entry index is stored as it is.
priv eval RT_EMPTY_WORD: u32 = 0xFFFFFFFFu32

/// `align_log2` and `flags` sit in what would otherwise be padding:
/// `entries()` takes no alignment, so the block records its own.
priv struct RawHeader {
    var cap:        usize // entries the block holds; 0 only in the shared empty block
    var shift:      u8    // 64 - log2(nslots)
    var align_log2: u8    // log2 of the entry alignment the block is laid out for
    var flags:      u8
    var seed:       u64
}

priv struct RawSlot {
    var hash32: u32 // top 32 bits of the key's hash
    var index:  u32 // entry index; RT_EMPTY_WORD when the slot is empty
}

priv struct RawEmptyBlock {
    var h: RawHeader
    var s: [u32; 4]  // two empty slots
}

/// What every empty table points at: two empty slots and shift 63, so a
/// lookup takes the normal path and stops at its first load. Never written,
/// never freed.
priv static RT_EMPTY_BLOCK: RawEmptyBlock = RawEmptyBlock {
    h: RawHeader { cap: 0, shift: 63, align_log2: 0, flags: 0, seed: 0 },
    s: [RT_EMPTY_WORD, RT_EMPTY_WORD, RT_EMPTY_WORD, RT_EMPTY_WORD],
}

// --- block layout -----------------------------------------------------------

priv inline fn rt_header(block: unsafe *u8) -> unsafe *RawHeader {
    unsafe {
        return block as unsafe *RawHeader
    }
}

priv inline fn rt_slots(block: unsafe *u8) -> unsafe *RawSlot {
    unsafe {
        return (block + sizeof RawHeader) as unsafe *RawSlot
    }
}

priv inline fn rt_nslots(shift: u8) -> usize {
    return 1usize << (64 - (shift as u32))
}

/// `rt_nslots(shift) - 1` in one shift.
priv inline fn rt_mask(shift: u8) -> usize {
    return (0xFFFFFFFFFFFFFFFFu64 >> (shift as u64)) as usize
}

/// Byte offset of entry 0 in a block of `nslots` slots whose entries are
/// aligned to `entry_align`. The one place that knows it.
priv inline fn rt_entries_offset(nslots: usize, entry_align: usize) -> usize {
    // The header and the slots end on a slot boundary, which is aligned
    // enough for any entry no more aligned than a slot or the header.
    if entry_align <= alignof RawSlot && sizeof RawHeader % entry_align == 0 {
        return sizeof RawHeader + nslots * sizeof RawSlot
    }

    return (sizeof RawHeader + nslots * sizeof RawSlot + entry_align - 1) & ~(entry_align - 1)
}

priv inline fn rt_block_align(entry_align: usize) -> usize {
    return (if entry_align > alignof RawHeader => entry_align else => alignof RawHeader)
}

priv inline fn rt_cap_for(nslots: usize) -> usize {
    return nslots - nslots / 8
}

/// The requested size passes the entry limit or does not fit the address
/// space.
@cold_path @no_inline
priv fn raw_table_too_large() -> ! {
    __builtin_trap()
}

@cold_path @no_inline
priv fn raw_table_alloc_fail() -> ! {
    __builtin_trap()
}

/// Bytes of a block of `nslots` slots; traps when the size does not fit.
priv fn rt_block_bytes(nslots: usize, entry_size: usize, entry_align: usize) -> usize {
    var entries: usize = 0
    if __builtin_mul_overflow(rt_cap_for(nslots), entry_size, &entries) {
        raw_table_too_large()
    }

    var index: usize = 0
    if __builtin_mul_overflow(nslots, sizeof RawSlot, &index) {
        raw_table_too_large()
    }

    var head: usize = 0
    // The header, the index and the padding before the entries.
    if __builtin_add_overflow(index, sizeof RawHeader + entry_align, &head) {
        raw_table_too_large()
    }

    var total: usize = 0
    if __builtin_add_overflow(
        rt_entries_offset(nslots, entry_align),
        entries,
        &total,
    ) {
        raw_table_too_large()
    }

    return total
}

/// The smallest slot count whose capacity holds `need` entries. Traps past
/// the entry limit.
priv fn raw_table_slots_for(need: usize) -> usize {
    if (need as u64) > RT_MAX_ENTRIES {
        raw_table_too_large()
    }

    var log: u32 = 3
    loop {
        var n = 1usize << log
        if rt_cap_for(n) >= need {
            return n
        }

        log += 1
        if log > RT_MAX_SLOTS_LOG2 || log >= (sizeof usize * 8) as u32 {
            raw_table_too_large()
        }
    }
}

priv inline fn rt_fill_empty(slots: unsafe *RawSlot, nslots: usize) {
    unsafe {
        __builtin_set_mem(
            slots as unsafe *u8,
            0xFF as byte,
            nslots * sizeof RawSlot,
        )
    }
}

/// A fresh block with an empty index. The entries are uninitialized.
priv fn rt_block_new(nslots:      usize,
                     entry_size:  usize,
                     entry_align: usize,
                     seed:        u64) -> unsafe *u8 {
    var bytes = rt_block_bytes(nslots, entry_size, entry_align)
    var block: unsafe *u8 = kairo_global_alloc(
        bytes,
        rt_block_align(entry_align),
    )

    if block == &null {
        raw_table_alloc_fail()
    }

    rt_fill_empty(rt_slots(block), nslots)
    unsafe {
        var unsafe *h = rt_header(block)
        h->cap        = rt_cap_for(nslots)
        h->shift      = (64 - __builtin_ctz(nslots)) as u8
        h->align_log2 = __builtin_ctz(entry_align) as u8
        h->flags      = 0
        h->seed       = seed
    }

    return block
}

/// Frees a block made by `rt_block_new` with the same entry size and
/// alignment.
priv fn rt_block_free(block: unsafe *u8, entry_size: usize, entry_align: usize) {
    unsafe {
        var nslots = rt_nslots(rt_header(block)->shift)
        kairo_global_free(
            block,
            rt_block_bytes(nslots, entry_size, entry_align),
            rt_block_align(entry_align),
        )
    }
}

/// Entry 0 of any block, from its own header.
priv inline fn rt_block_entries(block: unsafe *u8) -> unsafe *u8 {
    unsafe {
        var unsafe *h = rt_header(block)
        return block + rt_entries_offset(
            rt_nslots(h->shift),
            1usize << (h->align_log2 as u32),
        )
    }
}

/// The home slot of an occupied slot, from its cached hash bits alone.
priv inline fn rt_home(hash32: u32, shift: u8) -> usize {
    return (hash32 >> ((shift as u32) - 32)) as usize
}

/// Writes `(hash32, entry)` into the first empty slot at or after the home
/// of `hash32`. Returns the number of slots walked. The index has an empty
/// slot.
priv inline fn rt_place(slots:  unsafe *RawSlot,
                        mask:   usize,
                        shift:  u8,
                        hash32: u32,
                        entry:  u32) -> usize {
    var i             = rt_home(hash32, shift)
    var walked: usize = 0
    unsafe {
        while slots[i].index != RT_EMPTY_WORD {
            i = (i + 1) & mask
            walked += 1
        }

        slots[i].hash32 = hash32
        slots[i].index  = entry
    }

    return walked
}

/// Copies every occupied slot of `old` into the empty index `slots`. Entry
/// indices are unchanged; no key is hashed or read.
priv fn rt_rebuild(slots:      unsafe *RawSlot,
                   mask:       usize,
                   shift:      u8,
                   old:        unsafe *RawSlot,
                   old_nslots: usize) {
    var i: usize = 0
    unsafe {
        while i < old_nslots {
            var stored = old[i].index
            if stored != RT_EMPTY_WORD {
                rt_place(slots, mask, shift, old[i].hash32, stored)
            }

            i += 1
        }
    }
}

/// Empties slot `hole` and closes the gap: each later slot of the cluster
/// moves back into the hole unless that would put it before its home. The
/// scan runs to the cluster's end, not to the first slot sitting at its
/// home: insertion takes the first empty slot, so slots are not ordered by
/// home and one at its home can be followed by one far from its own.
priv fn rt_erase_slot(slots: unsafe *RawSlot, mask: usize, shift: u8, hole: usize) {
    var i = hole
    var j = hole
    unsafe {
        loop {
            j = (j + 1) & mask
            var stored = slots[j].index
            if stored == RT_EMPTY_WORD {
                break
            }

            var home = rt_home(slots[j].hash32, shift)
            // Movable when the home is not in (i, j] cyclically: the slot's
            // distance from its home reaches back to i or further.
            if ((j - home) & mask) >= ((j - i) & mask) {
                slots[i].hash32 = slots[j].hash32
                slots[i].index  = stored
                i               = j
            }
        }

        slots[i].hash32 = RT_EMPTY_WORD
        slots[i].index  = RT_EMPTY_WORD
    }
}

/// The slot that names `entry`, probing from the home of `hash`. The slot
/// exists.
priv inline fn rt_slot_of(slots: unsafe *RawSlot,
                          mask:  usize,
                          shift: u8,
                          hash:  u64,
                          entry: usize) -> usize {
    var i    = (hash >> (shift as u64)) as usize
    var want = entry as u32
    unsafe {
        while slots[i].index != want {
            i = (i + 1) & mask
        }
    }

    return i
}

/// The slot that names `entry`, by scanning the index. The slot exists.
priv fn rt_slot_scan(slots: unsafe *RawSlot, nslots: usize, entry: usize) -> usize {
    var want       = entry as u32
    var i:   usize = 0
    unsafe {
        while i < nslots {
            if slots[i].index == want {
                return i
            }

            i += 1
        }
    }

    __builtin_trap()
}

/// The shared empty block, as a table's block pointer.
priv inline fn rt_empty_block() -> *u8 {
    unsafe {
        return (unsafe &RT_EMPTY_BLOCK) as unsafe *u8 as *u8
    }
}

// --- seeds ------------------------------------------------------------------

priv eval RT_K0: u64 = 0x9e3779b97f4a7c15u64
priv eval RT_K1: u64 = 0xbf58476d1ce4e5b9u64
priv eval RT_K2: u64 = 0x94d049bb133111ebu64

/// The 128-bit product folded to 64 bits; two 32x32 products on targets
/// without a native 64x64->128 multiply.
priv inline fn rt_mum(a: u64, b: u64) -> u64 {
    eval if defined!(__x86_64__) || defined!(__aarch64__) || defined!(__LP64__) || defined!(_WIN64) || defined!(__mips64) {
        var r = (a as u128) * (b as u128)
        return (r as u64) ^ ((r >> 64) as u64)
    } else {
        var x = (a & 0xffffffffu64) * (b >> 32)
        var y = (a >> 32) * (b & 0xffffffffu64)
        return x ^ ((y << 32) | (y >> 32))
    }
}

// 0 until the first call. Racing first calls store the same value
// (`process_seed` depends only on static addresses), so every reader sees
// one seed.
priv var rt_process_seed_cache: u64 = 0

/// Reads the process-wide seed once and keeps it where a lookup can load it
/// with no call.
priv fn rt_process_seed_compute() -> u64 {
    var s = process_seed()
    rt_process_seed_cache = s
    return s
}

// Called from every inlined lookup: preserve_most keeps the lookup from
// saving registers around a call it makes once per process.
eval if defined!(__x86_64__) || defined!(__aarch64__) {
    @cold_path @preserve_most @no_inline
    priv fn rt_process_seed_init() -> u64 {
        return rt_process_seed_compute()
    }
} else {
    @cold_path @no_inline
    priv fn rt_process_seed_init() -> u64 {
        return rt_process_seed_compute()
    }
}

/// The per-process part of every table's seed: `process_seed()`, which
/// `-DKAIRO_HASH_SEED` pins so hashes and table layouts repeat from run to
/// run.
priv inline fn rt_process_seed() -> u64 {
    var s = rt_process_seed_cache
    @unlikely
    if s == 0 {
        s = rt_process_seed_init()
    }

    return s
}

/// `rt_process_seed` once a table exists: every table's constructor has
/// run `rt_process_seed`, so the cache is set and the lookup reads it with
/// no test.
priv inline fn rt_process_seed_set() -> u64 {
    return rt_process_seed_cache
}

/// The seed a table moves to when its probe sequences cluster.
priv fn rt_next_seed(seed: u64, len: usize) -> u64 {
    return rt_mum(seed ^ RT_K2 ^ (len as u64), RT_K0 ^ rt_process_seed())
}

// --- the table --------------------------------------------------------------

/// The storage behind HashMap and HashSet: a dense, insertion-ordered entry
/// array plus an open-addressing index of 8-byte slots that point into it.
/// One block:
///
///   [ header ][ slot x nslots ][ pad to entry align ][ entry x cap ]
///
/// `nslots` is a power of two and `cap = nslots - nslots / 8`, so a full
/// entry array and a full index are the same event. A slot caches the top
/// 32 bits of its key's hash; the home slot of a hash is its top
/// `log2(nslots)` bits, so a slot's home is recoverable from the slot alone
/// and neither growth nor deletion hashes a key or reads an entry.
///
/// Not generic: entries move as bytes, and every element type shares this
/// code. The owner constructs and destroys them; this class never runs an
/// element's constructor or destructor. An owner whose entries cannot move
/// as bytes uses `grow_begin` / `resize_end` and the `index_unlink_*` forms
/// and moves them itself.
///
/// The seed is fixed for a block's life and is inherited across growth,
/// shrink and clear (the owner hashes before it claims, so a seed change
/// inside `claim` would link the entry under a stale hash); only
/// `reseed_begin` changes it. Per-process entropy is mixed in by `hash_of`,
/// since every empty table shares one block.
@relocatable
prot class RawTable {
    // Never null: an empty table points at RT_EMPTY_BLOCK. Every operation
    // that writes the block checks `cap != 0` first or cannot reach it with
    // the empty block (`claim` grows first because `len == cap`).
    priv var block: *u8?
    priv var len:   usize

    prot inline fn RawTable(self) {
        self.block = rt_empty_block()
        self.len   = 0
        // Sets the cache `hash_of` reads.
        rt_process_seed()
    }

    @move prot inline fn RawTable(self, other: Self) { // bitwise; other becomes empty
        self.block  = other.block
        self.len    = other.len
        other.block = rt_empty_block()
        other.len   = 0
    }

    /// Takes `other`'s block and size; `other` becomes empty. This table
    /// holds the empty block.
    prot inline fn steal(self, other: *RawTable) {
        self.block   = other->block
        self.len     = other->len
        other->block = rt_empty_block()
        other->len   = 0
    }

    /// The block as a raw pointer: the one place that relies on `block`
    /// never being null.
    priv inline fn base(const self) -> unsafe *u8 {
        if self.block? {
            unsafe {
                return self.block as unsafe *u8
            }
        }

        __builtin_unreachable()
    }

    prot inline fn size(const self) -> usize {
        return self.len
    }

    prot inline fn capacity(const self) -> usize {
        unsafe {
            return rt_header(self.base())->cap
        }
    }

    prot inline fn seed(const self) -> u64 {
        unsafe {
            return rt_header(self.base())->seed
        }
    }

    /// Entry 0. For an empty table: a non-null address that holds no entry.
    prot inline fn entries(const self) -> *u8? { // entry 0
        unsafe {
            return self.entry_base() as *u8
        }
    }

    /// `entries()` as a raw pointer, for arithmetic.
    prot inline fn entry_base(const self) -> unsafe *u8 {
        return rt_block_entries(self.base())
    }

    /// `entries()` for an owner that knows the entry alignment at compile
    /// time: the offset folds to one shift and one mask.
    prot inline fn entries_aligned(const self, entry_align: usize) -> unsafe *u8 {
        unsafe {
            return self.base() + rt_entries_offset(
                rt_nslots(rt_header(self.base())->shift),
                entry_align,
            )
        }
    }

    // --- probing -----------------------------------------------------------

    prot inline fn first_slot(const self, hash: u64) -> usize {
        unsafe {
            return (hash >> (rt_header(self.base())->shift as u64)) as usize
        }
    }

    prot inline fn next_slot(const self, slot: usize) -> usize {
        unsafe {
            return (slot + 1) & (rt_nslots(rt_header(self.base())->shift) - 1)
        }
    }

    /// The entry index in `slot`; NO_ENTRY when the probe ends there.
    prot inline fn slot_entry(const self, slot: usize) -> usize { // NO_ENTRY: the probe ends here
        unsafe {
            var stored = rt_slots(self.base())[slot].index
            if stored == RT_EMPTY_WORD {
                return NO_ENTRY
            }

            return stored as usize
        }
    }

    /// True when the hash bits cached in `slot` agree with `hash`.
    prot inline fn slot_matches(const self, slot: usize, hash: u64) -> bool { // cached hash bits agree
        unsafe {
            return rt_slots(self.base())[slot].hash32 == (hash >> 32) as u32
        }
    }

    // --- growth ------------------------------------------------------------

    /// Swaps in a block of `nslots` slots whose index names the same entries
    /// and returns the previous block. The new block's entries are
    /// uninitialized.
    priv fn swap_block(self, nslots: usize, entry_size: usize, entry_align: usize) -> unsafe *u8 {
        var unsafe *old = self.base()
        unsafe {
            var unsafe *oh = rt_header(old)
            var unsafe *nb = rt_block_new(
                nslots,
                entry_size,
                entry_align,
                oh->seed,
            )

            rt_rebuild(
                rt_slots(nb),
                nslots - 1,
                rt_header(nb)->shift,
                rt_slots(old),
                rt_nslots(oh->shift),
            )

            self.block = nb as *u8
        }

        return old
    }

    /// Finishes a block swap: the bytes of the live entries move over and
    /// the previous block is freed.
    priv fn adopt_entries(self, old: unsafe *u8, entry_size: usize, entry_align: usize) {
        unsafe {
            if self.len != 0 {
                __builtin_copy(
                    rt_block_entries(self.base()),
                    rt_block_entries(old) as unsafe *const u8,
                    self.len * entry_size,
                )
            }
        }

        self.resize_end(old, entry_size, entry_align)
    }

    priv fn grown_slots(const self, need: usize) -> usize {
        var nslots = raw_table_slots_for(need)
        unsafe {
            var unsafe *h = rt_header(self.base())
            if h->cap != 0 {
                var doubled = rt_nslots(h->shift) * 2
                if doubled > nslots {
                    nslots = raw_table_slots_for(rt_cap_for(doubled))
                }
            }
        }

        return nslots
    }

    eval if defined!(__x86_64__) || defined!(__aarch64__) {
        @cold_path @preserve_most @no_inline
        priv fn grow(self, need: usize, entry_size: usize, entry_align: usize) {
            var unsafe *old = self.swap_block(self.grown_slots(need), entry_size, entry_align)
            self.adopt_entries(old, entry_size, entry_align)
        }
    } else {
        @cold_path @no_inline
        priv fn grow(self, need: usize, entry_size: usize, entry_align: usize) {
            var unsafe *old = self.swap_block(self.grown_slots(need), entry_size, entry_align)
            self.adopt_entries(old, entry_size, entry_align)
        }
    }

    /// Room for `n` entries in all, moving entry bytes. Never shrinks.
    prot fn reserve(self, n: usize, entry_size: usize, entry_align: usize) {
        if n <= self.capacity() {
            return
        }

        var unsafe *old = self.swap_block(
            raw_table_slots_for(n),
            entry_size,
            entry_align,
        )

        self.adopt_entries(old, entry_size, entry_align)
    }

    /// `reserve` for entries that do not move as bytes: returns the previous
    /// block, or null when the table already holds `n`. Finish as after
    /// `grow_begin`.
    prot fn reserve_begin(self, n: usize, entry_size: usize, entry_align: usize) -> unsafe *u8 {
        if n <= self.capacity() {
            return &null
        }

        return self.swap_block(raw_table_slots_for(n), entry_size, entry_align)
    }

    /// First half of growth for entries that do not move as bytes: after it
    /// the table has room for `need` entries and its index is complete, but
    /// its entry array is uninitialized. Returns the previous block; the
    /// owner moves entries `[0, size())` from `block_entries(previous)` to
    /// `entries()` and then calls `resize_end`.
    prot fn grow_begin(self, need: usize, entry_size: usize, entry_align: usize) -> unsafe *u8 {
        return self.swap_block(self.grown_slots(need), entry_size, entry_align)
    }

    /// As `grow_begin`, for shrinking to the smallest block that holds the
    /// entries. Returns null when the table is already that small; an empty
    /// table is released instead.
    prot fn shrink_begin(self, entry_size: usize, entry_align: usize) -> unsafe *u8 {
        if self.len == 0 {
            self.release(entry_size, entry_align)
            return &null
        }

        var nslots = raw_table_slots_for(self.len)
        unsafe {
            if nslots >= rt_nslots(rt_header(self.base())->shift) {
                return &null
            }
        }

        return self.swap_block(nslots, entry_size, entry_align)
    }

    /// Entry 0 of a block that `grow_begin` or `shrink_begin` returned.
    prot static inline fn block_entries(block: unsafe *u8) -> unsafe *u8 {
        return rt_block_entries(block)
    }

    /// Frees a block that `grow_begin` or `shrink_begin` returned.
    prot fn resize_end(self, previous: unsafe *u8, entry_size: usize, entry_align: usize) {
        unsafe {
            if rt_header(previous)->cap != 0 {
                rt_block_free(previous, entry_size, entry_align)
            }
        }
    }

    /// Gives this empty table a block of the same slot count and seed as
    /// `other`'s, with `other`'s index copied as bytes, so it names entries
    /// `[0, other.size())` at the same positions. The size stays 0 until the
    /// owner has copied the entries and calls `set_size`.
    prot fn copy_index_from(self, const other: RawTable, entry_size: usize, entry_align: usize) {
        unsafe {
            var unsafe *oh = rt_header(other.base())
            if oh->cap == 0 {
                return
            }

            var nslots = rt_nslots(oh->shift)
            var unsafe *nb = rt_block_new(
                nslots,
                entry_size,
                entry_align,
                oh->seed,
            )

            __builtin_copy(
                rt_slots(nb) as unsafe *u8,
                rt_slots(other.base()) as unsafe *const u8,
                nslots * sizeof RawSlot,
            )

            self.block = nb as *u8
        }
    }

    /// Records that entries `[0, n)` are constructed. Only after
    /// `copy_index_from`, with `n` the source's size.
    prot inline fn set_size(self, n: usize) {
        self.len = n
    }

    // --- insertion ---------------------------------------------------------

    /// Index of a new, unconstructed entry at the end, linked under `hash`.
    /// Grows by copying entry bytes when the table is full; an owner whose
    /// entries do not move as bytes makes room with `grow_begin` first.
    prot inline fn claim(self, hash: u64, entry_size: usize, entry_align: usize) -> usize { // index of a new, unconstructed entry at the end
        @unlikely
        if self.len == self.capacity() {
            self.grow(self.len + 1, entry_size, entry_align)
        }

        var entry = self.len
        unsafe {
            var unsafe *h     = rt_header(self.base())
            var        nslots = rt_nslots(h->shift)
            var walked = rt_place(
                rt_slots(self.base()),
                nslots - 1,
                h->shift,
                (hash >> 32) as u32,
                entry as u32,
            )

            self.len = entry + 1
            @unlikely
            if walked > RT_PROBE_LIMIT {
                self.long_probe(nslots)
            }
        }

        return entry
    }

    /// `claim` into `slot`, the empty slot where a lookup of `hash` in this
    /// table just stopped. The table is not full. Saves the second walk.
    prot inline fn claim_at(self, slot: usize, hash: u64) -> usize {
        var entry = self.len
        unsafe {
            var unsafe *h = rt_header(self.base())
            var unsafe *s = rt_slots(self.base()) + slot
            s->hash32 = (hash >> 32) as u32
            s->index  = entry as u32
            self.len  = entry + 1
            var nslots = rt_nslots(h->shift)
            @unlikely
            if ((slot - ((hash >> (h->shift as u64)) as usize)) & (nslots - 1)) > RT_PROBE_LIMIT {
                self.long_probe(nslots)
            }
        }

        return entry
    }

    /// `claim` on a full table: grows, then links. Out of line so an inlined
    /// insert carries one call and no probe loop for it. Not
    /// `@preserve_most`: the owners are in other files.
    @cold_path @no_inline
    prot fn claim_grow(self, hash: u64, entry_size: usize, entry_align: usize) -> usize {
        self.grow(self.len + 1, entry_size, entry_align)
        return self.claim(hash, entry_size, entry_align)
    }

    /// A long walk in an index under half full is a hash that clusters, not
    /// load: ask for a new seed, once per block.
    @cold_path @no_inline
    priv fn long_probe(self, nslots: usize) {
        unsafe {
            var unsafe *h = rt_header(self.base())
            if self.len < nslots / 2 && (h->flags & RT_FLAG_RESEEDED) == 0 {
                h->flags = h->flags | RT_FLAG_RESEED_WANTED
            }
        }
    }

    /// True when an insert met a long probe sequence in a sparse index. The
    /// owner then runs `reseed_begin` and claims every entry again.
    prot inline fn wants_reseed(const self) -> bool {
        unsafe {
            return (rt_header(self.base())->flags & RT_FLAG_RESEED_WANTED) != 0
        }
    }

    /// Installs `seed`, empties the index and sets the size to 0 without
    /// touching the entries. Returns the previous size `n`; the owner then
    /// calls `claim(hash_of(entry i), ..)` for `i` in `0..n`, in order, which
    /// links each entry under its new hash and returns `i`. A block is
    /// reseeded at most once, so a key type whose hash ignores the seed
    /// costs one pass per block and no more.
    prot fn reseed_begin(self, seed: u64) -> usize {
        var n = self.len
        unsafe {
            var unsafe *h = rt_header(self.base())
            if h->cap == 0 {
                return 0
            }

            h->seed  = seed
            h->flags = RT_FLAG_RESEEDED
            rt_fill_empty(rt_slots(self.base()), rt_nslots(h->shift))
        }

        self.len = 0
        return n
    }

    // --- removal: the index only -------------------------------------------

    /// Unlinks `entry` and repoints the slot of the last entry at `entry`'s
    /// position; the owner moves the last entry there. `hash` is `entry`'s
    /// and `last_hash` the last entry's. Size drops by one.
    prot fn index_unlink_swap(self, entry: usize, hash: u64, last_hash: u64) {
        unsafe {
            var unsafe *h = rt_header(self.base())
            self.index_unlink_swap_at(
                rt_slot_of(
                    rt_slots(self.base()),
                    rt_mask(h->shift),
                    h->shift,
                    hash,
                    entry,
                ),
                entry,
                last_hash,
            )
        }
    }

    /// `index_unlink_swap` given `at`, the slot that names `entry` (where
    /// the owner's lookup stopped).
    prot fn index_unlink_swap_at(self, at: usize, entry: usize, last_hash: u64) {
        unsafe {
            var unsafe *h     = rt_header(self.base())
            var unsafe *slots = rt_slots(self.base())
            var        mask   = rt_mask(h->shift)
            var        last   = self.len - 1
            if entry != last {
                // Before the erase: it moves slots.
                slots[rt_slot_of(slots, mask, h->shift, last_hash, last)].index = entry as u32
            }

            rt_erase_slot(slots, mask, h->shift, at)
            self.len = last
        }
    }

    /// Unlinks `entry` and renumbers every later entry down by one; the
    /// owner shifts the entries. One pass over the index. Size drops by one.
    prot fn index_unlink_shift(self, entry: usize) {
        unsafe {
            var unsafe *h           = rt_header(self.base())
            var unsafe *slots       = rt_slots(self.base())
            var        nslots       = rt_nslots(h->shift)
            var        want         = entry as u32
            var        at:    usize = NO_ENTRY
            var        i:     usize = 0
            while i < nslots {
                var e = slots[i].index
                if e != RT_EMPTY_WORD {
                    if e == want {
                        at = i
                    } else if e > want {
                        slots[i].index = e - 1
                    }
                }

                i += 1
            }

            if at == NO_ENTRY {
                __builtin_trap()
            }

            rt_erase_slot(slots, nslots - 1, h->shift, at)
            self.len -= 1
        }
    }

    /// Unlinks the last entry, whose hash is `last_hash`.
    prot fn index_unlink_last(self, last_hash: u64) {
        unsafe {
            var unsafe *h     = rt_header(self.base())
            var unsafe *slots = rt_slots(self.base())
            var        mask   = rt_mask(h->shift)
            rt_erase_slot(
                slots,
                mask,
                h->shift,
                rt_slot_of(slots, mask, h->shift, last_hash, self.len - 1),
            )

            self.len -= 1
        }
    }

    // --- removal: index and entry bytes ------------------------------------

    /// The last entry's bytes move into the hole. Takes no hash, so it finds
    /// both slots by scanning the index: O(nslots). The owners move the
    /// entry themselves and call `index_unlink_swap_at`.
    prot fn unlink_swap(self, entry: usize, entry_size: usize) { // last entry's bytes move into the hole
        unsafe {
            var unsafe *h     = rt_header(self.base())
            var unsafe *slots = rt_slots(self.base())
            var        nslots = rt_nslots(h->shift)
            var        last   = self.len - 1
            var        at     = rt_slot_scan(slots, nslots, entry)
            if entry != last {
                var unsafe *e = self.entry_base()
                __builtin_copy(
                    e + entry * entry_size,
                    (e + last * entry_size) as unsafe *const u8,
                    entry_size,
                )

                slots[rt_slot_scan(slots, nslots, last)].index = entry as u32
            }

            rt_erase_slot(slots, nslots - 1, h->shift, at)
            self.len = last
        }
    }

    /// Later entries shift down by one; insertion order is kept. O(n).
    prot fn unlink_shift(self, entry: usize, entry_size: usize) { // later entries shift down
        unsafe {
            var tail = self.len - 1 - entry
            if tail != 0 {
                var unsafe *e = self.entry_base() + entry * entry_size
                __builtin_move_mem(
                    e,
                    (e + entry_size) as unsafe *const u8,
                    tail * entry_size,
                )
            }
        }

        self.index_unlink_shift(entry)
    }

    /// Unlinks the last entry. Takes no hash, so it finds the slot by
    /// scanning the index: O(nslots). The owners call `index_unlink_last`.
    prot fn unlink_last(self) {
        unsafe {
            var unsafe *h     = rt_header(self.base())
            var unsafe *slots = rt_slots(self.base())
            var        nslots = rt_nslots(h->shift)
            rt_erase_slot(
                slots,
                nslots - 1,
                h->shift,
                rt_slot_scan(slots, nslots, self.len - 1),
            )

            self.len -= 1
        }
    }

    // --- whole-table operations --------------------------------------------

    /// Empties the index and sets the size to 0; the capacity and the seed
    /// stay. The owner has destroyed every entry, or claims them again.
    prot fn clear_index(self) { // after the owner destroyed every entry
        unsafe {
            var unsafe *h = rt_header(self.base())
            if h->cap != 0 {
                rt_fill_empty(rt_slots(self.base()), rt_nslots(h->shift))
            }
        }

        self.len = 0
    }

    /// Reallocates to the smallest block that holds the entries, moving
    /// entry bytes; an empty table gives its block back.
    prot fn shrink(self, entry_size: usize, entry_align: usize) {
        var unsafe *old = self.shrink_begin(entry_size, entry_align)
        if old != &null {
            self.adopt_entries(old, entry_size, entry_align)
        }
    }

    /// Frees the block and returns to the shared empty block. The owner has
    /// destroyed every entry.
    prot fn release(self, entry_size: usize, entry_align: usize) { // frees the block
        unsafe {
            if rt_header(self.base())->cap != 0 {
                rt_block_free(self.base(), entry_size, entry_align)
            }
        }

        self.block = rt_empty_block()
        self.len   = 0
    }

    // --- validation --------------------------------------------------------

    /// 0 when the structure is consistent, else the number of the first rule
    /// that fails:
    ///   1  the slot count is a power of two within the limits
    ///   2  cap is nslots - nslots / 8 (0 in the shared empty block)
    ///   3  len <= cap, so load <= 7/8
    ///   4  an occupied slot names an entry index >= len
    ///   5  two slots name the same entry
    ///   6  the number of occupied slots is not len
    ///   7  a slot's cached hash does not shift to a slot index
    ///   8  a slot sits before its home, or an empty slot lies between its
    ///      home and it (the entry is not reachable by probing)
    /// Linear in the slot count. For tests and fuzzers.
    prot fn check_invariants(const self) -> u32 {
        unsafe {
            var unsafe *h = rt_header(self.base())
            if h->shift > 63 || h->shift < (64 - RT_MAX_SLOTS_LOG2) as u8 {
                return 1
            }

            var nslots = rt_nslots(h->shift)
            var mask   = nslots - 1
            if h->cap == 0 {
                if self.base() != (unsafe &RT_EMPTY_BLOCK) as unsafe *u8 || nslots != 2 {
                    return 2
                }
            } else {
                if nslots < RT_MIN_SLOTS || h->cap != rt_cap_for(nslots) {
                    return 2
                }
            }

            if self.len > h->cap {
                return 3
            }

            var unsafe *slots = rt_slots(self.base())

            var        words = self.len / 64 + 1
            var unsafe *seen = kairo_global_alloc_zeroed(words * 8, 8) as unsafe *u64
            if seen == &null {
                raw_table_alloc_fail()
            }

            var fail:        u32   = 0
            var used:        usize = 0
            var first_empty: usize = NO_ENTRY
            var i:           usize = 0
            while i < nslots && fail == 0 {
                var stored = slots[i].index
                if stored == RT_EMPTY_WORD {
                    if first_empty == NO_ENTRY {
                        first_empty = i
                    }
                } else {
                    var e = stored as usize
                    used += 1
                    if e >= self.len {
                        fail = 4
                    } else if ((seen[e / 64] >> ((e % 64) as u64)) & 1) != 0 {
                        fail = 5
                    } else {
                        seen[e / 64] = seen[e / 64] | (1u64 << ((e % 64) as u64))
                        if rt_home(slots[i].hash32, h->shift) > mask {
                            fail = 7
                        }
                    }
                }

                i += 1
            }

            kairo_global_free(seen as unsafe *u8, words * 8, 8)
            if fail != 0 {
                return fail
            }

            if used != self.len {
                return 6
            }

            // Walk one full turn from an empty slot, counting the run of
            // occupied slots that ends at each position: a slot is reachable
            // exactly when its home lies inside that run.
            var run:  usize = 0
            var step: usize = 1
            while step <= nslots {
                var j = (first_empty + step) & mask
                if slots[j].index == RT_EMPTY_WORD {
                    run = 0
                } else {
                    run += 1
                    if ((j - rt_home(slots[j].hash32, h->shift)) & mask) >= run {
                        return 8
                    }
                }

                step += 1
            }
        }

        return 0
    }
}

// --- hashing ----------------------------------------------------------------

/// The table's hash of `k`: the table seed mixed with the process seed.
/// A scalar key is one fold and a finish, with no call.
prot inline fn <K impl Hash> hash_of(const t: RawTable, const k: K) -> u64 {
    var h = Hasher(t.seed() ^ rt_process_seed_set())
    k.hash(&h)
    return h.finish()
}

// --- lookup -----------------------------------------------------------------

/// Entry index of `k`, or NO_ENTRY. The key is at offset 0 of each entry;
/// `stride` is the entry size. One instance per key type, shared by
/// HashSet<K> and every HashMap<K, V> whose entry has that size. The 32
/// cached hash bits filter the key comparison, so a miss almost never reads
/// an entry.
@hot_path
prot inline fn <K impl Hash> raw_find(const t: RawTable,
                                      const k: K,
                                      hash:    u64,
                                      stride:  usize) -> usize {
    var slot: usize = 0
    unsafe {
        var align = 1usize << (rt_header(t.base())->align_log2 as u32)
        return raw_find_slot(t, k, hash, stride, align, &slot)
    }
}

/// `raw_find` for an owner that knows the entry's alignment at compile
/// time, so the entry array's offset folds to a shift and an add; it also
/// gives the slot where the probe stopped: the key's slot on a hit, the
/// empty slot a new entry for `hash` takes on a miss.
@hot_path
prot inline fn <K impl Hash> raw_find_slot(const t: RawTable,
                                           const k: K,
                                           hash:    u64,
                                           stride:  usize,
                                           align:   usize,
                                           at:      *usize) -> usize {
    unsafe {
        var unsafe *b     = t.base()
        var unsafe *h     = rt_header(b)
        var unsafe *slots = rt_slots(b)
        var        shift  = h->shift
        var        mask   = rt_mask(shift)
        var        tag    = (hash >> 32) as u32
        var        i      = (hash >> (shift as u64)) as usize
        loop {
            var stored = slots[i].index
            if stored == RT_EMPTY_WORD {
                *at = i
                return NO_ENTRY
            }

            if slots[i].hash32 == tag {
                var unsafe *e = b + rt_entries_offset(mask + 1, align) + (stored as usize) * stride
                if *(e as unsafe *const K) == k {
                    *at = i
                    return stored as usize
                }
            }

            i = (i + 1) & mask
        }
    }
}

// COMPILER-WORKAROUND(move-param-name): a call of `move(x)` from a generic
// whose parameter is not named `T` reaches C++ as `move(static_cast<T &&>(x))`,
// spelled with move's own parameter name, so it fails to compile whatever
// the instance. Each helper's parameter carries the caller's name, which
// makes the spelled cast the right one. Use `rt_mv_e` where the type is
// `E`, `rt_mv_k` for `K`, `rt_mv_v` for `V`, `rt_mv_item<J>` for `J::Item`, and
// `move` itself for `T`.
prot inline fn <E> rt_mv_e(@move x: E) -> E = x

prot inline fn <K> rt_mv_k(@move x: K) -> K = x

prot inline fn <V> rt_mv_v(@move x: V) -> V = x

prot inline fn <J impl Iterator> rt_mv_item(@move x: J::Item) -> J::Item = x

// --- the generic layer HashMap and HashSet share -----------------------------
//
// `E` is the entry type and `K` the key at its offset 0. Entries that move
// as bytes go through the non-generic paths above; the others are moved
// here, one constructor and one destructor per entry.

/// Entry `i` of `t`.
prot inline fn <E> rt_entry(const t: RawTable, i: usize) -> unsafe *E {
    unsafe {
        return (t.entries_aligned(alignof E) + i * sizeof E) as unsafe *E
    }
}

/// Moves `n` entries from `src` to the uninitialized `dst`, front to back,
/// leaving the source storage uninitialized. `dst` lies below `src` or the
/// two do not overlap.
prot fn <E> rt_move_entries(dst: unsafe *E, src: unsafe *E, n: usize) {
    var i: usize = 0
    while i < n {
        unsafe {
            __builtin_construct_at<E>((dst + i) as unsafe *u8, rt_mv_e(src[i]))
            __builtin_destruct_at((src + i) as *E)
        }

        i += 1
    }
}

/// Moves one entry to uninitialized storage.
prot inline fn <E> rt_relocate(dst: unsafe *E, src: unsafe *E) {
    eval if __builtin_is_trivially_relocatable<E>() {
        unsafe {
            // Words, not __builtin_copy, when they fit: the copy stays
            // inline at a constant size. The test folds at compile time.
            if sizeof E % 8 == 0 && sizeof E <= 64 && alignof E >= 8 {
                var unsafe *d       = dst as unsafe *u64
                var unsafe *s       = src as unsafe *const u64
                var        i: usize = 0
                while i < sizeof E / 8 {
                    d[i] = s[i]
                    i += 1
                }
            } else {
                __builtin_copy(
                    dst as unsafe *u8,
                    src as unsafe *const u8,
                    sizeof E,
                )
            }
        }
    } else {
        unsafe {
            __builtin_construct_at<E>(dst as unsafe *u8, rt_mv_e(*src))
            __builtin_destruct_at(src as *E)
        }
    }
}

/// Runs the destructor of entries `[0, size())`.
prot fn <E> rt_destroy_entries(const t: RawTable) {
    eval if !__builtin_is_trivially_destructible<E>() {
        var unsafe *p       = rt_entry<E>(t, 0)
        var        n        = t.size()
        var        i: usize = 0
        while i < n {
            unsafe {
                __builtin_destruct_at((p + i) as *E)
            }

            i += 1
        }
    }
}

/// Finishes `grow_begin`, `reserve_begin` or `shrink_begin` for entries that
/// do not move as bytes. `old` may be null (nothing was swapped).
prot fn <E> rt_resize_end(t: *RawTable, old: unsafe *u8) {
    if old == &null {
        return
    }

    unsafe {
        rt_move_entries<E>(
            rt_entry<E>(*t, 0),
            RawTable::block_entries(old) as unsafe *E,
            t->size(),
        )
    }

    t->resize_end(old, sizeof E, alignof E)
}

@cold_path @no_inline
prot fn <E> rt_grow_moving(t: *RawTable, need: usize) {
    rt_resize_end<E>(t, t->grow_begin(need, sizeof E, alignof E))
}

/// Index of a new, unconstructed entry linked under `hash`. `slot` is where
/// a lookup of `hash` in this table just stopped: while the table has room
/// the entry takes it, with no second walk.
prot inline fn <E> rt_link(t: *RawTable, hash: u64, slot: usize) -> usize {
    @likely
    if t->size() < t->capacity() {
        return t->claim_at(slot, hash)
    }

    eval if __builtin_is_trivially_relocatable<E>() {
        return t->claim_grow(hash, sizeof E, alignof E)
    } else {
        rt_grow_moving<E>(t, t->size() + 1)
        return t->claim(hash, sizeof E, alignof E)
    }
}

/// Links entries again under a new seed, after an insert met a long probe
/// sequence in a sparse index.
@cold_path @no_inline
prot fn <E, K impl Hash> rt_reseed(t: *RawTable) {
    var n        = t->reseed_begin(rt_next_seed(t->seed(), t->size()))
    var i: usize = 0
    while i < n {
        unsafe {
            var unsafe *k = rt_entry<E>(*t, i) as unsafe *const K
            t->claim(hash_of(*t, *k), sizeof E, alignof E)
        }

        i += 1
    }
}

/// After the entry an insert linked is constructed.
prot inline fn <E, K impl Hash> rt_inserted(t: *RawTable) {
    @unlikely
    if t->wants_reseed() {
        rt_reseed<E, K>(t)
    }
}

/// Unlinks entry `e`, whose hash is `hash` and which the owner has destroyed;
/// the last entry moves into its place. O(1).
///
/// `at` is the slot that names `e`, where the owner's lookup stopped.
prot fn <E, K impl Hash> rt_remove_swap(t: *RawTable, at: usize, e: usize) {
    var last = t->size() - 1
    var lh   = 0u64
    if e != last {
        var unsafe *lp = rt_entry<E>(*t, last)
        unsafe {
            lh = hash_of(*t, *(lp as unsafe *const K))
        }

        rt_relocate<E>(rt_entry<E>(*t, e), lp)
    }

    t->index_unlink_swap_at(at, e, lh)
}

/// Unlinks entry `e`, which the owner has destroyed; later entries shift
/// down, so insertion order is kept. O(n).
prot fn <E> rt_remove_shift(t: *RawTable, e: usize) {
    eval if __builtin_is_trivially_relocatable<E>() {
        t->unlink_shift(e, sizeof E)
    } else {
        unsafe {
            rt_move_entries<E>(
                rt_entry<E>(*t, e),
                rt_entry<E>(*t, e + 1),
                t->size() - 1 - e,
            )
        }

        t->index_unlink_shift(e)
    }
}

/// Unlinks the last entry, which the owner has destroyed; `hash` is its.
prot inline fn rt_remove_last(t: *RawTable, hash: u64) {
    t->index_unlink_last(hash)
}

/// Links entries `[0, kept)` again after the owner has compacted them in
/// order (destroyed the rest and moved the survivors down).
prot fn <E, K impl Hash> rt_compact_end(t: *RawTable, kept: usize) {
    t->clear_index()
    var i: usize = 0
    while i < kept {
        unsafe {
            var unsafe *k = rt_entry<E>(*t, i) as unsafe *const K
            t->claim(hash_of(*t, *k), sizeof E, alignof E)
        }

        i += 1
    }
}

prot fn <E> rt_reserve(t: *RawTable, n: usize) {
    eval if __builtin_is_trivially_relocatable<E>() {
        t->reserve(n, sizeof E, alignof E)
    } else {
        rt_resize_end<E>(t, t->reserve_begin(n, sizeof E, alignof E))
    }
}

prot fn <E> rt_shrink(t: *RawTable) {
    eval if __builtin_is_trivially_relocatable<E>() {
        t->shrink(sizeof E, alignof E)
    } else {
        rt_resize_end<E>(t, t->shrink_begin(sizeof E, alignof E))
    }
}

prot inline fn <E> rt_clear(t: *RawTable) {
    rt_destroy_entries<E>(*t)
    t->clear_index()
}

prot inline fn <E> rt_release(t: *RawTable) {
    rt_destroy_entries<E>(*t)
    t->release(sizeof E, alignof E)
}
