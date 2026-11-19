/// builtin/containers/raw_table.k
///
/// The table behind HashMap and HashSet. Entries live densely, in insertion
/// order; in front of them sits an open-addressing index of one-line
/// buckets. One block, aligned to a bucket:
///
///   [ header ][ bucket x nbuckets ][ hash: u32 x cap ][ pad ][ entry x cap ]
///
///   bucket  64 bytes: 12 tags, 4 filler bytes, 12 entry numbers (u32).
///           A tag is 0xFF for an empty slot, 0x80 for a tombstone, else
///           the top 7 bits of the key's hash. A tag and the entry number
///           it guards share a cache line.
///   hash    the top 32 bits of each entry's hash, in entry order. An
///           entry's home bucket (the low bits of these 32) and its tag
///           (the top 7) come from here, so growth, removal and an index
///           rebuild hash no key and read no entry.
///
/// A lookup compares the 12 tags of the key's home bucket in one step,
/// follows each matching tag to its entry, and stops at the first bucket
/// that holds an empty slot: with a hash that spreads, a hit reads one
/// bucket and one entry and a miss one bucket, and both take the same
/// branches every time. Buckets follow each other at triangular distances.
/// `nbuckets` is a power of two and `cap = 8 * nbuckets`: at most two
/// thirds of the slots are full, which keeps full buckets rare (one in
/// nine at capacity, one in a thousand at half of it).
///
/// Removal leaves a tombstone only in a bucket with no empty slot, which a
/// probe sequence may have passed; otherwise the slot is empty again. The
/// header counts the empty slots inserts may still take (`room`). When
/// tombstones have used it up, the index is rebuilt in place from the hash
/// array if the table is at most half full, and the block doubles
/// otherwise.
///
/// Limits: entry numbers are 32 bits and a block has at most `2^29`
/// buckets, so a table holds at most `2^32` entries. Above `2^25` buckets the tag shares bits with the home bucket
/// and filters one bit less per doubling; a 64-bit hash array would lift
/// that.

ffi "c++" import "rt/global_alloc.h"
ffi "c++" import "raw_group.h"

import base::cmp::*
import base::copy::*
import base::hash::*
import base::intrinsics::*
import base::iter::*
import string::*

prot eval NO_ENTRY: usize = usize::MAX

priv eval RT_MAX_ENTRIES:      u64 = 0x100000000u64
priv eval RT_MAX_BUCKETS_LOG2: u32 = 29

/// Bytes in a bucket, slots in a bucket, entries a bucket adds to the
/// capacity, and where its entry numbers start.
priv eval RT_BUCKET: usize = 64
priv eval RT_SLOTS:  usize = 12
priv eval RT_LOAD:   usize = 8
priv eval RT_IDX:    usize = 16

/// An insert that walks more buckets than this while under half the slots
/// are full asks the owner for a new seed.
priv eval RT_PROBE_LIMIT: usize = 10

priv eval RT_FLAG_RESEED_WANTED: u8 = 1
priv eval RT_FLAG_RESEEDED:      u8 = 2

priv eval RT_EMPTY: u8 = 0xFF
priv eval RT_DEAD:  u8 = 0x80

/// The header takes the place of a bucket before the first one.
priv struct RawHeader {
    var cap:        usize // entries the block holds; 0 only in the shared empty block
    var mask:       usize // nbuckets - 1
    var room:       usize // empty slots inserts may still take: cap - len - tombstones
    var ent:        usize // byte offset of entry 0 from the block
    var seed:       u64
    var align_log2: u8    // log2 of the entry alignment the block is laid out for
    var flags:      u8
}

// The filler bytes of a bucket word, after its 12 empty tags.
eval if defined!(__BIG_ENDIAN__) {
    priv eval RT_EMPTY_TAIL: u64 = 0xFFFFFFFF80808080u64
} else {
    priv eval RT_EMPTY_TAIL: u64 = 0x80808080FFFFFFFFu64
}

/// What every empty table points at: a zero header (one bucket, no
/// capacity, no room) and, where the first bucket starts, the tags of an
/// empty bucket, so a lookup takes the normal path and stops at its first
/// bucket. Never freed. Its seed is written once, by the first table
/// constructed, and is the seed every block starts from.
priv static RT_EMPTY_BLOCK: [u64; 10] = [
    0,                     0,             0, 0, 0, 0, 0, 0,
    0xFFFFFFFFFFFFFFFFu64, RT_EMPTY_TAIL,
]

priv inline fn rt_empty_raw() -> unsafe *u8 {
    unsafe {
        return (unsafe &RT_EMPTY_BLOCK[0]) as unsafe *u8
    }
}

// --- buckets ----------------------------------------------------------------
//
// A bucket starts with 16 bytes: 12 tags and 4 filler bytes that hold the
// tombstone value, which matches no hash tag and is not empty. The three
// questions a probe asks of a bucket each give a mask of its slots.
//
// With SSE2 the 16 bytes are compared as one vector (raw_group.h); any
// other target reads them as one 128-bit word. `-DKAIRO_TABLE_NO_SIMD`
// takes the word form anywhere, which is how an x86-64 host tests it.

eval if defined!(__SSE2__) && !defined!(KAIRO_TABLE_NO_SIMD) {
    /// One bit per slot.
    priv type RtMask = u32

    priv inline fn rt_g_match(p: unsafe *const u8, tag: u8) -> RtMask {
        return kairo_group_match(p, tag)
    }

    priv inline fn rt_g_empty(p: unsafe *const u8) -> RtMask {
        return kairo_group_empty(p)
    }

    priv inline fn rt_g_free(p: unsafe *const u8) -> RtMask {
        return kairo_group_free(p)
    }

    priv inline fn rt_m_first(m: RtMask) -> usize {
        return __builtin_ctz(m) as usize
    }
} else {
    /// The 16 bytes as one little-endian word; the high bit of byte `i` for
    /// slot `i`.
    priv type RtMask = u128

    priv eval RT_ONES: u128 = ((0x0101010101010101u64 as u128) << 64) | (0x0101010101010101u64 as u128)
    priv eval RT_HIGH: u128 = ((0x8080808080808080u64 as u128) << 64) | (0x8080808080808080u64 as u128)
    priv eval RT_HIGH12: u128 = ((0x0000000080808080u64 as u128) << 64) | (0x8080808080808080u64 as u128)

    priv inline fn rt_load64(p: unsafe *const u8) -> u64 {
        var v: u64 = 0
        unsafe {
            __builtin_copy(&v as unsafe *u8, p, 8)
        }

        eval if defined!(__BIG_ENDIAN__) {
            return __builtin_bswap(v)
        } else {
            return v
        }
    }

    priv inline fn rt_g_load(p: unsafe *const u8) -> u128 {
        unsafe {
            return ((rt_load64(p + 8) as u128) << 64) | (rt_load64(p) as u128)
        }
    }

    /// A slot above a true match may be reported when its tag is `tag ^ 1`;
    /// that is a full slot, and the key comparison rejects it.
    priv inline fn rt_g_match(p: unsafe *const u8, tag: u8) -> RtMask {
        // The tag in every byte, from one 64-bit multiply: a 128-bit
        // multiply is a library call on 32-bit targets.
        var t = (tag as u64) * 0x0101010101010101u64
        var x = rt_g_load(p) ^ (((t as u128) << 64) | (t as u128))
        return (x - RT_ONES) & ~x & RT_HIGH
    }

    /// Bits 7 and 6 of an empty tag are both set.
    priv inline fn rt_g_empty(p: unsafe *const u8) -> RtMask {
        var g = rt_g_load(p)
        return g & (g << 1) & RT_HIGH
    }

    priv inline fn rt_g_free(p: unsafe *const u8) -> RtMask {
        return rt_g_load(p) & RT_HIGH12
    }

    priv inline fn rt_m_first(m: RtMask) -> usize {
        var lo = m as u64
        if lo != 0 {
            return (__builtin_ctz(lo) >> 3) as usize
        }

        return 8 + (__builtin_ctz((m >> 64) as u64) >> 3) as usize
    }
}

/// The tag of a hash: its top 7 bits.
priv inline fn rt_tag(hash: u64) -> u8 {
    return (hash >> 57) as u8
}

/// The 32 bits the hash array keeps.
priv inline fn rt_h32(hash: u64) -> u32 {
    return (hash >> 32) as u32
}

priv inline fn rt_tag32(h32: u32) -> u8 {
    return (h32 >> 25) as u8
}

// --- block layout -----------------------------------------------------------
//
// A slot is named by `bucket * 16 + i`: the byte offset of its tag from the
// first bucket is `bucket * 64 + i`.

priv inline fn rt_header(block: unsafe *u8) -> unsafe *RawHeader {
    unsafe {
        return block as unsafe *RawHeader
    }
}

priv inline fn rt_bucket(block: unsafe *u8, b: usize) -> unsafe *u8 {
    unsafe {
        return block + (b + 1) * RT_BUCKET
    }
}

priv inline fn rt_tag_at(block: unsafe *u8, slot: usize) -> unsafe *u8 {
    unsafe {
        return rt_bucket(block, slot >> 4) + (slot & 15)
    }
}

priv inline fn rt_idx_at(block: unsafe *u8, slot: usize) -> unsafe *u32 {
    unsafe {
        return (rt_bucket(block, slot >> 4) + RT_IDX + (slot & 15) * 4) as unsafe *u32
    }
}

priv inline fn rt_hashes(block: unsafe *u8, nbuckets: usize) -> unsafe *u32 {
    unsafe {
        return (block + (nbuckets + 1) * RT_BUCKET) as unsafe *u32
    }
}

/// Byte offset of entry 0 in a block of `nbuckets` buckets whose entries
/// are aligned to `entry_align`. The one place that knows it.
priv inline fn rt_entries_offset(nbuckets: usize, entry_align: usize) -> usize {
    var end = (nbuckets + 1) * RT_BUCKET + nbuckets * RT_LOAD * 4
    return (end + entry_align - 1) & ~(entry_align - 1)
}

priv inline fn rt_block_align(entry_align: usize) -> usize {
    return (if entry_align > RT_BUCKET => entry_align else => RT_BUCKET)
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

/// Bytes of a block of `nbuckets` buckets; traps when the size does not
/// fit.
priv fn rt_block_bytes(nbuckets: usize, entry_size: usize, entry_align: usize) -> usize {
    var entries: usize = 0
    if __builtin_mul_overflow(nbuckets * RT_LOAD, entry_size, &entries) {
        raw_table_too_large()
    }

    // Header, buckets and hashes: 96 bytes a bucket.
    var index: usize = 0
    if __builtin_mul_overflow(nbuckets, RT_BUCKET + RT_LOAD * 4, &index) {
        raw_table_too_large()
    }

    var head: usize = 0
    if __builtin_add_overflow(index, RT_BUCKET + entry_align, &head) {
        raw_table_too_large()
    }

    var total: usize = 0
    if __builtin_add_overflow(
        rt_entries_offset(nbuckets, entry_align),
        entries,
        &total,
    ) {
        raw_table_too_large()
    }

    return total
}

/// The smallest bucket count whose capacity holds `need` entries. Traps
/// past the entry limit.
priv fn raw_table_buckets_for(need: usize) -> usize {
    if (need as u64) > RT_MAX_ENTRIES {
        raw_table_too_large()
    }

    var log: u32 = 0
    loop {
        var n = 1usize << log
        if n * RT_LOAD >= need {
            return n
        }

        log += 1
        if log > RT_MAX_BUCKETS_LOG2 || log + 4 >= (sizeof usize * 8) as u32 {
            raw_table_too_large()
        }
    }
}

/// Makes every slot of `nbuckets` buckets empty.
priv fn rt_fill_empty(block: unsafe *u8, nbuckets: usize) {
    unsafe {
        var unsafe *p = rt_bucket(block, 0)
        __builtin_set_mem(p, RT_EMPTY as byte, nbuckets * RT_BUCKET)
        var b: usize = 0
        while b < nbuckets {
            var unsafe *f = p + b * RT_BUCKET + RT_SLOTS
            f[0] = RT_DEAD
            f[1] = RT_DEAD
            f[2] = RT_DEAD
            f[3] = RT_DEAD
            b += 1
        }
    }
}

/// A fresh block with an empty index. The hashes and the entries are
/// uninitialized.
priv fn rt_block_new(nbuckets:    usize,
                     entry_size:  usize,
                     entry_align: usize,
                     seed:        u64) -> unsafe *u8 {
    var bytes = rt_block_bytes(nbuckets, entry_size, entry_align)
    var block: unsafe *u8 = kairo_global_alloc(
        bytes,
        rt_block_align(entry_align),
    )

    if block == &null {
        raw_table_alloc_fail()
    }

    rt_fill_empty(block, nbuckets)
    unsafe {
        var unsafe *h = rt_header(block)
        h->cap        = nbuckets * RT_LOAD
        h->mask       = nbuckets - 1
        h->room       = nbuckets * RT_LOAD
        h->ent        = rt_entries_offset(nbuckets, entry_align)
        h->seed       = seed
        h->align_log2 = __builtin_ctz(entry_align) as u8
        h->flags      = 0
    }

    return block
}

/// Frees a block made by `rt_block_new` with the same entry size and
/// alignment.
priv fn rt_block_free(block: unsafe *u8, entry_size: usize, entry_align: usize) {
    unsafe {
        kairo_global_free(
            block,
            rt_block_bytes(rt_header(block)->mask + 1, entry_size, entry_align),
            rt_block_align(entry_align),
        )
    }
}

/// Entry 0 of any block, from its own header.
priv inline fn rt_block_entries(block: unsafe *u8) -> unsafe *u8 {
    unsafe {
        return block + rt_header(block)->ent
    }
}

/// The first slot that holds no entry on the probe sequence of the hash
/// bits `h32`; `*walked` gets the buckets passed on the way. Such a slot
/// exists.
priv inline fn rt_free_slot(block: unsafe *u8, mask: usize, h32: u32, walked: *usize) -> usize {
    var b           = (h32 as usize) & mask
    var step: usize = 0
    loop {
        var m = rt_g_free(rt_bucket(block, b))
        if m != 0 {
            *walked = step
            return b * 16 + rt_m_first(m)
        }

        step += 1
        b = (b + step) & mask
    }
}

/// Empties the index of `block` and links entries `[0, len)` again from the
/// hash array. No key is hashed and no entry is read.
priv fn rt_rebuild(block: unsafe *u8, len: usize) {
    unsafe {
        var unsafe *h   = rt_header(block)
        var        mask = h->mask
        var unsafe *hs  = rt_hashes(block, mask + 1)
        rt_fill_empty(block, mask + 1)
        var i:      usize = 0
        var walked: usize = 0
        while i < len {
            var s = rt_free_slot(block, mask, hs[i], &walked)
            *rt_tag_at(block, s) = rt_tag32(hs[i])
            *rt_idx_at(block, s) = i as u32
            i += 1
        }

        h->room = h->cap - len
    }
}

/// The slot that names `entry`, whose hash bits are `h32`. The slot exists.
priv inline fn rt_slot_of(block: unsafe *u8, mask: usize, h32: u32, entry: usize) -> usize {
    var b           = (h32 as usize) & mask
    var step: usize = 0
    var tag         = rt_tag32(h32)
    var want        = entry as u32
    unsafe {
        loop {
            var unsafe *p = rt_bucket(block, b)
            var        m  = rt_g_match(p, tag)
            while m != 0 {
                var j = rt_m_first(m)
                if *((p + RT_IDX + j * 4) as unsafe *u32) == want {
                    return b * 16 + j
                }

                m = m & (m - 1)
            }

            step += 1
            b = (b + step) & mask
        }
    }
}

/// Takes the entry out of slot `s`. In a bucket with an empty slot no probe
/// sequence has passed, and the slot becomes empty; in a bucket without
/// one it becomes a tombstone, so the sequences that passed still do.
/// Returns 1 when the slot became empty.
priv inline fn rt_erase(block: unsafe *u8, s: usize) -> usize {
    unsafe {
        if rt_g_empty(rt_bucket(block, s >> 4)) != 0 {
            *rt_tag_at(block, s) = RT_EMPTY
            return 1
        }

        *rt_tag_at(block, s) = RT_DEAD
        return 0
    }
}

/// The shared empty block, as a table's block pointer.
priv inline fn rt_empty_block() -> *u8 {
    unsafe {
        return rt_empty_raw() as *u8
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

/// Gives the empty block the process-wide seed: `process_seed()`, which
/// `-DKAIRO_HASH_SEED` pins so hashes and table layouts repeat from run to
/// run. Racing first calls store the same value. Every block inherits its
/// seed from the block it replaces, so every table starts from this one
/// and a lookup reads its seed from the block header alone.
@cold_path @no_inline
priv fn rt_seed_init() {
    unsafe {
        var unsafe *h = rt_header(rt_empty_raw())
        h->seed = process_seed()
        h->ent  = RT_BUCKET + 16
    }
}

/// The seed a table moves to when its probe sequences cluster.
priv fn rt_next_seed(seed: u64, len: usize) -> u64 {
    return rt_mum(seed ^ RT_K2 ^ (len as u64), RT_K0 ^ process_seed())
}

// --- the table --------------------------------------------------------------

/// The storage behind HashMap and HashSet; the layout is at the top of this
/// file.
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
/// `reseed_begin` changes it.
@relocatable
prot class RawTable {
    // Never null: an empty table points at RT_EMPTY_BLOCK. Every operation
    // that writes the block checks `cap != 0` first or cannot reach it with
    // the empty block (its `room` is 0, so an insert makes a block first).
    priv var block: *u8?
    priv var len:   usize

    prot inline fn RawTable(self) {
        self.block = rt_empty_block()
        self.len   = 0
        unsafe {
            @unlikely
            if rt_header(rt_empty_raw())->seed == 0 {
                rt_seed_init()
            }
        }
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

        unsafe {
            __builtin_unreachable()
        }
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

    // --- probing, one slot at a time ---------------------------------------
    //
    // Lookups probe a bucket at a time (`raw_find_slot`). These four walk
    // every full slot in slot order instead, which finds any entry but is
    // linear in the slot count: a slot alone does not say where a probe
    // sequence goes next. `first_slot` returns the first full slot, whatever
    // the hash.

    priv fn full_from(const self, slot: usize) -> usize {
        unsafe {
            var unsafe *b  = self.base()
            var        end = (rt_header(b)->mask + 1) * 16
            var        s   = slot
            while s < end && ((s & 15) >= RT_SLOTS || *rt_tag_at(b, s) >= RT_DEAD) {
                s += 1
            }

            return s
        }
    }

    prot inline fn first_slot(const self, hash: u64) -> usize {
        return self.full_from(0)
    }

    prot inline fn next_slot(const self, slot: usize) -> usize {
        return self.full_from(slot + 1)
    }

    /// The entry index in `slot`; NO_ENTRY when the walk is past the last
    /// slot.
    prot inline fn slot_entry(const self, slot: usize) -> usize { // NO_ENTRY: the probe ends here
        unsafe {
            if slot >= (rt_header(self.base())->mask + 1) * 16 {
                return NO_ENTRY
            }

            return *rt_idx_at(self.base(), slot) as usize
        }
    }

    /// True when the tag of `slot` is the tag of `hash`.
    prot inline fn slot_matches(const self, slot: usize, hash: u64) -> bool { // cached hash bits agree
        unsafe {
            return *rt_tag_at(self.base(), slot) == rt_tag(hash)
        }
    }

    // --- growth ------------------------------------------------------------

    /// Swaps in a block of `nbuckets` buckets whose index names the same
    /// entries and returns the previous block. The new block's entries are
    /// uninitialized.
    priv fn swap_block(self, nbuckets: usize, entry_size: usize, entry_align: usize) -> unsafe *u8 {
        var unsafe *old = self.base()
        unsafe {
            var unsafe *oh = rt_header(old)
            var unsafe *nb = rt_block_new(
                nbuckets,
                entry_size,
                entry_align,
                oh->seed,
            )

            if self.len != 0 {
                __builtin_copy(
                    rt_hashes(nb, nbuckets) as unsafe *u8,
                    rt_hashes(old, oh->mask + 1) as unsafe *const u8,
                    self.len * 4,
                )

                rt_rebuild(nb, self.len)
            }

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

    priv fn grown_buckets(const self, need: usize) -> usize {
        var n = raw_table_buckets_for(need)
        unsafe {
            var unsafe *h = rt_header(self.base())
            if h->cap != 0 {
                var doubled = (h->mask + 1) * 2
                if doubled > n {
                    n = raw_table_buckets_for(doubled * RT_LOAD)
                }
            }
        }

        return n
    }

    eval if defined!(__x86_64__) || defined!(__aarch64__) {
        @cold_path @preserve_most @no_inline
        priv fn grow(self, need: usize, entry_size: usize, entry_align: usize) {
            var unsafe *old = self.swap_block(self.grown_buckets(need), entry_size, entry_align)
            self.adopt_entries(old, entry_size, entry_align)
        }
    } else {
        @cold_path @no_inline
        priv fn grow(self, need: usize, entry_size: usize, entry_align: usize) {
            var unsafe *old = self.swap_block(self.grown_buckets(need), entry_size, entry_align)
            self.adopt_entries(old, entry_size, entry_align)
        }
    }

    /// True when the block holds `n` entries in all without another block.
    /// Tombstones may hold the room for them: then the index is rebuilt in
    /// place, which moves no entry.
    priv fn holds(self, n: usize) -> bool {
        unsafe {
            var unsafe *h = rt_header(self.base())
            if n > h->cap {
                return false
            }

            if n > self.len && n - self.len > h->room {
                rt_rebuild(self.base(), self.len)
            }

            return true
        }
    }

    /// Room for `n` entries in all, moving entry bytes: the next
    /// `n - size()` inserts change no capacity. Never shrinks.
    prot fn reserve(self, n: usize, entry_size: usize, entry_align: usize) {
        if self.holds(n) {
            return
        }

        var unsafe *old = self.swap_block(
            raw_table_buckets_for(n),
            entry_size,
            entry_align,
        )

        self.adopt_entries(old, entry_size, entry_align)
    }

    /// `reserve` for entries that do not move as bytes: returns the previous
    /// block, or null when the table already holds `n`. Finish as after
    /// `grow_begin`.
    prot fn reserve_begin(self, n: usize, entry_size: usize, entry_align: usize) -> unsafe *u8 {
        if self.holds(n) {
            return &null
        }

        return self.swap_block(
            raw_table_buckets_for(n),
            entry_size,
            entry_align,
        )
    }

    /// First half of growth for entries that do not move as bytes: after it
    /// the table has room for `need` entries and its index is complete, but
    /// its entry array is uninitialized. Returns the previous block; the
    /// owner moves entries `[0, size())` from `block_entries(previous)` to
    /// `entries()` and then calls `resize_end`.
    prot fn grow_begin(self, need: usize, entry_size: usize, entry_align: usize) -> unsafe *u8 {
        return self.swap_block(
            self.grown_buckets(need),
            entry_size,
            entry_align,
        )
    }

    /// As `grow_begin`, for shrinking to the smallest block that holds the
    /// entries. Returns null when the table is already that small; an empty
    /// table is released instead.
    prot fn shrink_begin(self, entry_size: usize, entry_align: usize) -> unsafe *u8 {
        if self.len == 0 {
            self.release(entry_size, entry_align)
            return &null
        }

        var n = raw_table_buckets_for(self.len)
        unsafe {
            if n >= rt_header(self.base())->mask + 1 {
                return &null
            }
        }

        return self.swap_block(n, entry_size, entry_align)
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

    /// Gives this empty table a block of the same bucket count and seed as
    /// `other`'s, with `other`'s buckets and hashes copied as bytes, so it
    /// names entries `[0, other.size())` at the same positions. The size
    /// stays 0 until the owner has copied the entries and calls `set_size`.
    prot fn copy_index_from(self, const other: RawTable, entry_size: usize, entry_align: usize) {
        unsafe {
            var unsafe *ob = other.base()
            var unsafe *oh = rt_header(ob)
            if oh->cap == 0 {
                return
            }

            var        n   = oh->mask + 1
            var unsafe *nb = rt_block_new(n, entry_size, entry_align, oh->seed)

            // The buckets and the hashes of the live entries are one run.
            __builtin_copy(
                rt_bucket(nb, 0),
                rt_bucket(ob, 0) as unsafe *const u8,
                n * RT_BUCKET + other.len * 4,
            )

            rt_header(nb)->room = oh->room
            self.block          = nb as *u8
        }
    }

    /// Records that entries `[0, n)` are constructed. Only after
    /// `copy_index_from`, with `n` the source's size.
    prot inline fn set_size(self, n: usize) {
        self.len = n
    }

    // --- insertion ---------------------------------------------------------

    /// True when no empty slot is left for an insert and making one needs a
    /// larger block: the table is full, or tombstones fill it while it is
    /// more than half full. An owner whose entries do not move as bytes
    /// then makes room with `grow_begin` before it claims.
    prot inline fn wants_block(const self) -> bool {
        unsafe {
            var unsafe *h = rt_header(self.base())
            return h->room == 0 && (h->cap == 0 || self.len > h->cap / 2)
        }
    }

    /// Makes `room` positive: rebuilds the index in place when tombstones
    /// hold the room of a table at most half full, else grows, copying
    /// entry bytes.
    priv fn make_room(self, entry_size: usize, entry_align: usize) {
        if self.wants_block() {
            self.grow(self.len + 1, entry_size, entry_align)
        } else {
            rt_rebuild(self.base(), self.len)
        }
    }

    /// Index of a new, unconstructed entry at the end, linked under `hash`.
    /// Grows by copying entry bytes when the table is full; an owner whose
    /// entries do not move as bytes checks `wants_block` and makes room with
    /// `grow_begin` first.
    prot fn claim(self, hash: u64, entry_size: usize, entry_align: usize) -> usize { // index of a new, unconstructed entry at the end
        unsafe {
            if rt_header(self.base())->room == 0 {
                self.make_room(entry_size, entry_align)
            }

            var unsafe *b            = self.base()
            var unsafe *h            = rt_header(b)
            var        entry         = self.len
            var        h32           = rt_h32(hash)
            var        walked: usize = 0
            // A tombstone on the way is taken before the first empty slot;
            // only an empty one uses room. An empty tag is odd, a
            // tombstone even.
            var        s  = rt_free_slot(b, h->mask, h32, &walked)
            var unsafe *t = rt_tag_at(b, s)
            h->room -= (*t & 1) as usize
            *t                               = rt_tag32(h32)
            *rt_idx_at(b, s)                 = entry as u32
            rt_hashes(b, h->mask + 1)[entry] = h32
            self.len                         = entry + 1
            if walked > RT_PROBE_LIMIT {
                self.long_probe()
            }

            return entry
        }
    }

    /// True when `claim_at(slot, ..)` may run: a miss reported `slot` and
    /// an empty slot may still be taken.
    prot inline fn takes(const self, slot: usize) -> bool {
        unsafe {
            return slot != NO_ENTRY && rt_header(self.base())->room != 0
        }
    }

    /// `claim` into `slot`, the slot a miss of `hash` in this table just
    /// reported for a new entry, after `takes(slot)`. No walk. Returns the
    /// address of the new, unconstructed entry; `entry_size` is its size.
    prot inline fn claim_at(self, slot: usize, hash: u64, entry_size: usize) -> unsafe *u8 {
        unsafe {
            var unsafe *b     = self.base()
            var unsafe *h     = rt_header(b)
            var        entry  = self.len
            var unsafe *place = b + h->ent + entry * entry_size
            var unsafe *hs    = rt_hashes(b, h->mask + 1)
            var unsafe *t     = rt_tag_at(b, slot)
            // An empty tag is odd, a tombstone even.
            h->room -= (*t & 1) as usize
            *t                  = rt_tag(hash)
            *rt_idx_at(b, slot) = entry as u32
            hs[entry]           = rt_h32(hash)
            self.len            = entry + 1
            return place
        }
    }

    /// A long walk while under half the slots are full is a hash that
    /// clusters, not load: ask for a new seed, once per block.
    @cold_path @no_inline
    priv fn long_probe(self) {
        unsafe {
            var unsafe *h = rt_header(self.base())
            if self.len < (h->mask + 1) * (RT_SLOTS / 2) && (h->flags & RT_FLAG_RESEEDED) == 0 {
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
            h->room  = h->cap
            rt_fill_empty(self.base(), h->mask + 1)
        }

        self.len = 0
        return n
    }

    // --- removal: the index only -------------------------------------------

    /// Unlinks `entry`, which slot `at` names (where the owner's lookup
    /// stopped), and repoints the slot of the last entry at `entry`'s
    /// position; the owner moves the last entry there. Size drops by one.
    prot fn index_unlink_swap_at(self, at: usize, entry: usize) {
        unsafe {
            var unsafe *b   = self.base()
            var unsafe *h   = rt_header(b)
            var        mask = h->mask
            var unsafe *hs  = rt_hashes(b, mask + 1)
            var        last = self.len - 1
            if entry != last {
                var lh = hs[last]
                *rt_idx_at(b, rt_slot_of(b, mask, lh, last)) = entry as u32
                hs[entry]                                    = lh
            }

            h->room += rt_erase(b, at)
            self.len = last
        }
    }

    /// `index_unlink_swap_at` when the owner has no slot: finds it from the
    /// entry's stored hash.
    prot fn index_unlink_swap(self, entry: usize) {
        self.index_unlink_swap_at(self.slot_of(entry), entry)
    }

    /// The slot that names `entry`.
    priv fn slot_of(const self, entry: usize) -> usize {
        unsafe {
            var unsafe *b   = self.base()
            var        mask = rt_header(b)->mask
            return rt_slot_of(b, mask, rt_hashes(b, mask + 1)[entry], entry)
        }
    }

    /// Unlinks `entry` and renumbers every later entry down by one; the
    /// owner shifts the entries. One pass over the index. Size drops by one.
    prot fn index_unlink_shift(self, entry: usize) {
        var at = self.slot_of(entry)
        unsafe {
            var unsafe *b  = self.base()
            var unsafe *h  = rt_header(b)
            var        n   = h->mask + 1
            var unsafe *hs = rt_hashes(b, n)
            h->room += rt_erase(b, at)
            var tail = self.len - 1 - entry
            if tail != 0 {
                __builtin_move_mem(
                    (hs + entry) as unsafe *u8,
                    (hs + entry + 1) as unsafe *const u8,
                    tail * 4,
                )
            }

            var want       = entry as u32
            var k:   usize = 0
            while k < n {
                var unsafe *p         = rt_bucket(b, k)
                var unsafe *idx       = (p + RT_IDX) as unsafe *u32
                var        j:   usize = 0
                while j < RT_SLOTS {
                    if p[j] < RT_DEAD && idx[j] > want {
                        idx[j] -= 1
                    }

                    j += 1
                }

                k += 1
            }

            self.len -= 1
        }
    }

    /// Unlinks the last entry.
    prot fn index_unlink_last(self) {
        var at = self.slot_of(self.len - 1)
        unsafe {
            rt_header(self.base())->room += rt_erase(self.base(), at)
            self.len -= 1
        }
    }

    // --- removal: index and entry bytes ------------------------------------

    /// The last entry's bytes move into the hole.
    prot fn unlink_swap(self, entry: usize, entry_size: usize) { // last entry's bytes move into the hole
        unsafe {
            var last = self.len - 1
            if entry != last {
                var unsafe *e = self.entry_base()
                __builtin_copy(
                    e + entry * entry_size,
                    (e + last * entry_size) as unsafe *const u8,
                    entry_size,
                )
            }
        }

        self.index_unlink_swap(entry)
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

    prot fn unlink_last(self) {
        self.index_unlink_last()
    }

    // --- whole-table operations --------------------------------------------

    /// Empties the index and sets the size to 0; the capacity and the seed
    /// stay. The owner has destroyed every entry, or claims them again.
    prot fn clear_index(self) { // after the owner destroyed every entry
        unsafe {
            var unsafe *h = rt_header(self.base())
            if h->cap != 0 {
                rt_fill_empty(self.base(), h->mask + 1)
                h->room = h->cap
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
    ///    1  the bucket count is a power of two within the limits
    ///    2  cap is 8 * nbuckets and the entry offset is the layout's (the
    ///       shared empty block: one bucket, cap 0, no room)
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
    /// Linear in the slot count for a hash that spreads. For tests and
    /// fuzzers.
    prot fn check_invariants(const self) -> u32 {
        unsafe {
            var unsafe *b   = self.base()
            var unsafe *h   = rt_header(b)
            var        mask = h->mask
            var        n    = mask + 1
            if (n & mask) != 0 || n > (1usize << RT_MAX_BUCKETS_LOG2) {
                return 1
            }

            if h->cap == 0 {
                if b != rt_empty_raw() || n != 1 || h->room != 0 {
                    return 2
                }

                if self.len != 0 {
                    return 3
                }

                var unsafe *e0       = rt_bucket(b, 0)
                var        j0: usize = 0
                while j0 < RT_SLOTS {
                    if e0[j0] != RT_EMPTY {
                        return 5
                    }

                    j0 += 1
                }

                return 0
            }

            if h->cap != n * RT_LOAD
                || h->ent != rt_entries_offset(
                    n,
                    1usize << (h->align_log2 as u32),
                ) {
                return 2
            }

            if self.len > h->cap {
                return 3
            }

            var unsafe *hs = rt_hashes(b, n)

            // seen[e]: entry e is named. mark[k]: 1 + the home whose probe
            // sequence was last walked over bucket k.
            var unsafe *seen = kairo_global_alloc_zeroed(self.len + 1, 1)
            var unsafe *mark = kairo_global_alloc_zeroed(n * sizeof usize, alignof usize) as unsafe *usize
            if seen == &null || mark == &null {
                raw_table_alloc_fail()
            }

            var fail: u32   = 0
            var full: usize = 0
            var dead: usize = 0
            var k:    usize = 0
            while k < n && fail == 0 {
                var unsafe *p       = rt_bucket(b, k)
                var        j: usize = RT_SLOTS
                while j < 16 {
                    if p[j] != RT_DEAD {
                        fail = 4
                    }

                    j += 1
                }

                j = 0
                while j < RT_SLOTS && fail == 0 {
                    var t = p[j]
                    if t == RT_DEAD {
                        dead += 1
                    } else if t != RT_EMPTY {
                        var e = *((p + RT_IDX + j * 4) as unsafe *u32) as usize
                        if t > RT_DEAD {
                            fail = 5
                        } else if e >= self.len {
                            fail = 6
                        } else if seen[e] != 0 {
                            fail = 7
                        } else if t != rt_tag32(hs[e]) {
                            fail = 8
                        } else {
                            seen[e] = 1
                            full += 1
                            // Walk the probe sequence from the entry's home
                            // up to the first bucket with an empty slot,
                            // unless a walk from the same home already
                            // covered this bucket.
                            var home = (hs[e] as usize) & mask
                            if mark[k] != home + 1 {
                                var at          = home
                                var step: usize = 0
                                loop {
                                    mark[at] = home + 1
                                    if rt_g_empty(rt_bucket(b, at)) != 0 || step > n {
                                        break
                                    }

                                    step += 1
                                    at = (at + step) & mask
                                }

                                if mark[k] != home + 1 {
                                    fail = 11
                                }
                            }
                        }
                    }

                    j += 1
                }

                k += 1
            }

            kairo_global_free(seen, self.len + 1, 1)
            kairo_global_free(
                mark as unsafe *u8,
                n * sizeof usize,
                alignof usize,
            )

            if fail != 0 {
                return fail
            }

            if full != self.len {
                return 9
            }

            if self.len + dead > h->cap || h->room != h->cap - self.len - dead {
                return 10
            }
        }

        return 0
    }
}

// --- hashing ----------------------------------------------------------------

/// The table's hash of `k`, under the block's seed. A scalar key is two
/// folds, with no call.
prot inline fn <K impl Hash> hash_of(const t: RawTable, const k: K) -> u64 {
    var h = Hasher(t.seed())
    k.hash(&h)
    return h.finish()
}

// --- lookup -----------------------------------------------------------------

/// Entry index of `k`, or NO_ENTRY. The key is at offset 0 of each entry;
/// `stride` is the entry size. One instance per key type, shared by
/// HashSet<K> and every HashMap<K, V> whose entry has that size.
@hot_path
prot inline fn <K impl Hash> raw_find(const t: RawTable,
                                      const k: K,
                                      hash:    u64,
                                      stride:  usize) -> usize {
    var slot: usize = 0
    return raw_find_slot(t, k, hash, stride, &slot)
}

/// `raw_find` that also gives a slot: on a hit the key's slot; on a miss
/// the slot a new entry for `hash` takes, which is the first one on the
/// probe sequence that holds no entry, or NO_ENTRY after a long walk.
///
/// The 7 tag bits filter the key comparison: a miss reads an entry once in
/// about 128 full slots it passes.
@hot_path
prot inline fn <K impl Hash> raw_find_slot(const t: RawTable,
                                           const k: K,
                                           hash:    u64,
                                           stride:  usize,
                                           at:      *usize) -> usize {
    unsafe {
        var unsafe *blk        = t.base()
        var unsafe *h          = rt_header(blk)
        var        mask        = h->mask
        var unsafe *ent        = blk + h->ent
        var        tag         = rt_tag(hash)
        var        b           = (rt_h32(hash) as usize) & mask
        var        step: usize = 0
        var        free        = NO_ENTRY
        loop {
            var unsafe *p = rt_bucket(blk, b)
            var        m  = rt_g_match(p, tag)
            while m != 0 {
                var j = rt_m_first(m)
                var e = *((p + RT_IDX + j * 4) as unsafe *u32) as usize
                if *((ent + e * stride) as unsafe *const K) == k {
                    *at = b * 16 + j
                    return e
                }

                m = m & (m - 1)
            }

            // The first slot without an entry: a caller that only looks up
            // drops this.
            if free == NO_ENTRY {
                var f = rt_g_free(p)
                if f != 0 {
                    free = b * 16 + rt_m_first(f)
                }
            }

            @likely
            if rt_g_empty(p) != 0 {
                // After a long walk no slot is reported: `claim` walks
                // again and judges the probe length.
                *at = (if step > RT_PROBE_LIMIT => NO_ENTRY else => free)
                return NO_ENTRY
            }

            step += 1
            b = (b + step) & mask
        }
    }
}

// --- the generic layer HashMap and HashSet share -----------------------------
//
// `E` is the entry type and `K` the key at its offset 0. Entries that move
// as bytes go through the non-generic paths above; the others are moved
// here, one constructor and one destructor per entry.

/// Entry `i` of `t`.
prot inline fn <E> rt_entry(const t: RawTable, i: usize) -> unsafe *E {
    unsafe {
        return (t.entry_base() + i * sizeof E) as unsafe *E
    }
}

/// Moves `n` entries from `src` to the uninitialized `dst`, front to back,
/// leaving the source storage uninitialized. `dst` lies below `src` or the
/// two do not overlap.
prot fn <E> rt_move_entries(dst: unsafe *E, src: unsafe *E, n: usize) {
    var i: usize = 0
    while i < n {
        unsafe {
            __builtin_construct_at<E>((dst + i) as unsafe *u8, move(src[i]))
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
            __builtin_construct_at<E>(dst as unsafe *u8, move(*src))
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

/// `rt_link` for entries that do not move as bytes, when the lookup's slot
/// cannot be taken.
@cold_path @no_inline
prot fn <E> rt_link_moving(t: *RawTable, hash: u64) -> usize {
    if t->wants_block() {
        rt_grow_moving<E>(t, t->size() + 1)
    }

    return t->claim(hash, sizeof E, alignof E)
}

/// The address of a new, unconstructed entry linked under `hash`, at index
/// `size() - 1`. `slot` is what a miss of `hash` in this table just reported
/// for it: while an empty slot may be taken the entry goes there, with no
/// second walk.
prot inline fn <E> rt_link(t: *RawTable, hash: u64, slot: usize) -> unsafe *u8 {
    @likely
    if t->takes(slot) {
        return t->claim_at(slot, hash, sizeof E)
    }

    unsafe {
        eval if __builtin_is_trivially_relocatable<E>() {
            var i = t->claim(hash, sizeof E, alignof E)
            return rt_entry<E>(*t, i) as unsafe *u8
        } else {
            var i = rt_link_moving<E>(t, hash)
            return rt_entry<E>(*t, i) as unsafe *u8
        }
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

/// Unlinks entry `e`, which slot `at` names (where the owner's lookup
/// stopped) and which the owner has destroyed; the last entry moves into
/// its place. O(1), and no key is hashed.
prot inline fn <E, K impl Hash> rt_remove_swap(t: *RawTable, at: usize, e: usize) {
    var last = t->size() - 1
    if e != last {
        rt_relocate<E>(rt_entry<E>(*t, e), rt_entry<E>(*t, last))
    }

    t->index_unlink_swap_at(at, e)
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

/// Unlinks the last entry, which the owner has destroyed.
prot inline fn rt_remove_last(t: *RawTable) {
    t->index_unlink_last()
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
