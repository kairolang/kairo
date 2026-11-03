/// --- The Kairo Project ------------ Lib/builtin/containers/hash_map.k --- ///
///
///   \brief The HashMap lang item: `{K: V}`.
///
///   \detail
///     A dense array of entries in insertion order plus an open-addressing
///     index (containers/hash_index.k has the layout). What that buys:
///
///     ORDER. Iteration -- `for (k, v) in m`, `m.entries()`, begin()..end()
///     -- visits entries in INSERTION order, the same on every run and every
///     target: nothing depends on hash values or addresses. Re-inserting a
///     present key (`insert`, `m[k] = v`) keeps its place. `erase` is O(1)
///     and moves the LAST entry into the erased one's place (swap-remove),
///     so after an erase the order is insertion order with that one move;
///     `erase_ordered` keeps the order exactly, for O(len). Sorted order is
///     not provided: sort the keys where it matters.
///
///     ITERATION AND MUTATION. Inserting or erasing during a `for ... in m`
///     is undefined (it may reallocate the entries); so is using a pointer
///     from find / begin / `[]` / get across an insert or erase. To erase
///     while walking, walk the indices backwards (`entries()` and
///     erase_ordered, or swap-remove from the end).
///
///     COST. Lookup: one hash, one multiply, a slot load, a tag compare and
///     one key compare on a hit. Insert of a new key: the same probe plus a
///     slot store and the entry's construction; growth (doubling, out of
///     line) relocates the entries and re-places the slots from their tags
///     without rehashing. A table is never more than half full.
///
///     COPY. A copy is deep: every entry is copied (K and V's own copies).
///     There is no cheap move yet: a COPY class cannot also declare `@move`
///     (SC057E), so passing a map by value copies it (pass `const m` to
///     read). Moving the entries on growth copies them unless the entry is
///     trivially relocatable.
///
///     Migration from Stage 0's map / unordered_map: `m.find(k) == m.end()`
///     and `it->first` / `it->second` read as `m.find(k) == m.end()` and
///     `it->key` / `it->value` (find returns a pointer to the entry, end()
///     one past the last); `m.get(k)` is the nullable form. `erase(k)`
///     returns whether it erased (Stage 0 returned a count).
///
///   Allocation is the allocator in effect (base/alloc.k's alloc_raw /
///   free_raw): one block per map, nothing for an empty one.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import base::intrinsics::*
import base::alloc::*
import base::hash::*
import containers::slice::*
import containers::hash_index::*

/// One key and its value, as a map stores them. No constructor: it is a
/// C++ aggregate, built in place as `MapEntry(k, v)` and `MapEntry(k)` (C++20
/// parenthesized aggregate initialization; the value value-initialized), so
/// each member is constructed directly from its argument. A Kairo
/// constructor would default-construct `key` before assigning it: a field of
/// a generic type is not one CtorInitLowering initializes in place, and a
/// key with no default constructor would not compile.
pub class <K, V> MapEntry {
    pub var key:   K
    pub var value: V
}

pub class <K impl Hash, V> HashMap {
    /// slots, then entries: one block (hash_index.k). Never null: while
    /// cap == 0 it is a dangling pointer aligned for the entries, so the
    /// entry array is `block + 16 * cap` with no test and begin() == end()
    /// is a valid empty range. Slots are read only while len > 0.
    priv var block: unsafe *u8
    priv var len:   usize
    priv var cap:   usize
    priv var shift: u32

    pub inline fn HashMap(self) {
        self.block = block_empty(alignof MapEntry<K, V>)
        self.len = 0
        self.cap = 0
        self.shift = 0
    }

    /// `{k: v, ...}` (ListLiteralLowering): the entries in written order; a
    /// repeated key keeps its first place and takes its last value.
    pub fn HashMap(self, const items: [(K, V);]) {
        self.block = block_empty(alignof MapEntry<K, V>)
        self.len = 0
        self.cap = 0
        self.shift = 0
        if items.len == 0 { return }
        self.grow(items.len)
        var i: usize = 0
        while i < items.len {
            var e = self.intern(items.data[i].0)
            unsafe { (self.entry_array() + e)->value = items.data[i].1 }
            i += 1
        }
    }

    /// A deep copy: the same capacity, the same slots, every entry copied.
    @copy
    pub fn HashMap(self, const other: Self) {
        self.block = block_empty(alignof MapEntry<K, V>)
        self.len = 0
        self.cap = 0
        self.shift = other.shift
        if other.cap == 0 { return }
        var unsafe *b = block_alloc(other.cap, sizeof MapEntry<K, V>, alignof MapEntry<K, V>)
        unsafe { __builtin_copy(b, other.block, other.cap * 16) }
        self.block = b
        self.cap = other.cap
        var unsafe *src = other.entry_array()
        var unsafe *dst = self.entry_array()
        var i: usize = 0
        while i < other.len {
            unsafe { __builtin_construct_at<MapEntry<K, V>>((dst + i) as unsafe *u8, src[i]) }
            i += 1
            self.len = i
        }
    }

    fn op delete(self) {
        self.destroy_entries()
        block_free(self.block, self.cap, sizeof MapEntry<K, V>, alignof MapEntry<K, V>)
    }

    // --- size ---------------------------------------------------------------

    pub inline fn size(const self) -> usize { return self.len }
    pub inline fn empty(const self) -> bool { return self.len == 0 }
    /// Entries that fit before the next growth.
    pub inline fn capacity(const self) -> usize { return self.cap }

    // --- lookup -------------------------------------------------------------

    pub inline fn contains(const self, const k: K) -> bool { return self.index_of(k) != HASH_NPOS }

    /// The entry for k, or end().
    pub inline fn find(self, const k: K) -> *MapEntry<K, V> {
        var e = self.index_of(k)
        if e == HASH_NPOS { return self.end() }
        unsafe { return (self.entry_array() + e) as *MapEntry<K, V> }
    }

    /// k's value, or null.
    pub inline fn get(self, const k: K) -> *V? {
        var e = self.index_of(k)
        if e == HASH_NPOS { return null }
        unsafe { return &(self.entry_array() + e)->value as unsafe *V as *V }
    }

    /// k's value as a place, inserted default-constructed when absent.
    pub inline fn op [] (self, const k: K) -> *V {
        var t = tag_of(k.hash())
        var slot: usize = 0
        var e = HASH_NPOS
        if self.len != 0 { e = self.probe(k, t, &slot) }
        if e == HASH_NPOS { e = self.add_default(slot, t, k) }
        unsafe { return &(self.entry_array() + e)->value as unsafe *V as *V }
    }

    // --- iteration (insertion order) -----------------------------------------

    /// The first entry; end() when empty.
    pub inline fn begin(self) -> *MapEntry<K, V> {
        unsafe { return self.entry_array() as *MapEntry<K, V> }
    }

    /// One past the last entry.
    pub inline fn end(self) -> *MapEntry<K, V> {
        unsafe { return (self.entry_array() + self.len) as *MapEntry<K, V> }
    }

    /// Every entry, in order, as a view: `for *e in m.entries()` walks them
    /// with no copy.
    pub inline fn entries(self) -> [MapEntry<K, V>;] {
        unsafe { return Slice<MapEntry<K, V>>(self.entry_array() as *MapEntry<K, V>, self.len) }
    }

    /// `for (k, v) in m`: each key and value, copied, in order.
    pub fn op in (self) -> yield (K, V) {
        var i: usize = 0
        while i < self.len {
            unsafe {
                var unsafe *e = self.entry_array() + i
                // Named first: a prvalue tuple does not bind the promise's
                // yield_value (CL001E, a non-const lvalue reference).
                var kv = (e->key, e->value)
                yield kv
            }
            i += 1
        }
    }

    // --- insertion ------------------------------------------------------------

    /// Adds (k, v) when k is absent; true if it did. A present key keeps its
    /// value and its place.
    pub inline fn insert(self, const k: K, const v: V) -> bool {
        var t = tag_of(k.hash())
        var slot: usize = 0
        if (self.len != 0) && (self.probe(k, t, &slot) != HASH_NPOS) { return false }
        self.add(slot, t, k, v)
        return true
    }

    /// Stage 0's `emplace(k, v)`: insert.
    pub inline fn emplace(self, const k: K, const v: V) -> bool { return self.insert(k, v) }

    /// Room for n entries without growing.
    pub fn reserve(self, n: usize) {
        if n > self.cap { self.grow(n) }
    }

    // --- removal ----------------------------------------------------------------

    /// Removes k; true if it was there. O(1): the last entry moves into k's
    /// place (see the header on order).
    pub fn erase(self, const k: K) -> bool {
        if self.len == 0 { return false }
        var t = tag_of(k.hash())
        var slot: usize = 0
        var e = self.probe(k, t, &slot)
        if e == HASH_NPOS { return false }
        var mask = self.cap * 2 - 1
        remove_slot(self.slot_table(), mask, self.shift, slot)
        var unsafe *es = self.entry_array()
        var last = self.len - 1
        unsafe { __builtin_destruct_at((es + e) as *MapEntry<K, V>) }
        if e != last {
            unsafe {
                var lt = tag_of((es + last)->key.hash())
                var ls = slot_of_entry(self.slot_table(), mask, self.shift, lt, last)
                relocate_entry((es + e) as unsafe *u8, es + last)
                self.slot_table()[ls] = slot_word(lt, e)
            }
        }
        self.len = last
        return true
    }

    /// Removes k keeping every other entry's order; true if it was there.
    /// O(len): the entries after k move down one, and every slot is renumbered.
    pub fn erase_ordered(self, const k: K) -> bool {
        if self.len == 0 { return false }
        var t = tag_of(k.hash())
        var slot: usize = 0
        var e = self.probe(k, t, &slot)
        if e == HASH_NPOS { return false }
        remove_slot(self.slot_table(), self.cap * 2 - 1, self.shift, slot)
        var unsafe *es = self.entry_array()
        unsafe { __builtin_destruct_at((es + e) as *MapEntry<K, V>) }
        var i = e
        while i + 1 < self.len {
            unsafe { relocate_entry((es + i) as unsafe *u8, es + (i + 1)) }
            i += 1
        }
        shift_down_after(self.slot_table(), self.cap * 2, e)
        self.len -= 1
        return true
    }

    /// Removes every entry; keeps the capacity.
    pub fn clear(self) {
        if self.cap == 0 { return }
        self.destroy_entries()
        self.len = 0
        unsafe { __builtin_set_mem(self.block, 0 as byte, self.cap * 16) }
    }

    // --- internals ----------------------------------------------------------------

    priv inline fn slot_table(const self) -> unsafe *u64 { return block_slots(self.block) }

    /// The entries (`block`'s note: valid, if dangling, while cap == 0).
    priv inline fn entry_array(const self) -> unsafe *MapEntry<K, V> {
        unsafe { return block_entries(self.block, self.cap) as unsafe *MapEntry<K, V> }
    }

    /// k's entry index, or HASH_NPOS.
    priv inline fn index_of(const self, const k: K) -> usize {
        if self.len == 0 { return HASH_NPOS }
        var slot: usize = 0
        return self.probe(k, tag_of(k.hash()), &slot)
    }

    /// k's entry index, or HASH_NPOS with `*slot` the empty slot where k
    /// would go. Only while len > 0: an empty map may have no table.
    priv inline fn probe(const self, const k: K, t: u32, slot: *usize) -> usize {
        var mask = self.cap * 2 - 1
        var i = (t >> self.shift) as usize
        var unsafe *ss = self.slot_table()
        var unsafe *es = self.entry_array()
        unsafe {
            while true {
                var s = ss[i]
                if s == 0 { break }
                if slot_tag(s) == t {
                    var e = slot_entry(s)
                    if (es + e)->key == k { (*slot) = i; return e }
                }
                i = (i + 1) & mask
            }
        }
        (*slot) = i
        return HASH_NPOS
    }

    /// k's entry index, inserting k with a default value when absent.
    priv inline fn intern(self, const k: K) -> usize {
        var t = tag_of(k.hash())
        var slot: usize = 0
        if self.len != 0 {
            var e = self.probe(k, t, &slot)
            if e != HASH_NPOS { return e }
        }
        return self.add_default(slot, t, k)
    }

    /// The slot a new key with tag t goes in, growing first when the entries
    /// are full: `slot` (probe's miss) unless the table moved or was empty.
    priv inline fn place(self, t: u32, slot: usize) -> usize {
        if self.len == self.cap {
            self.grow(self.len + 1)
            return empty_slot(self.slot_table(), self.cap * 2 - 1, self.shift, t)
        }
        if self.len == 0 { return (t >> self.shift) as usize }
        return slot
    }

    /// A new entry (k, v) at the end; `slot` is probe's miss. Out of line:
    /// the construction (and any growth) is the cost, and the lookup paths
    /// that reach it stay small enough to inline.
    @no_inline
    priv fn add(self, miss: usize, t: u32, const k: K, const v: V) {
        var slot = self.place(t, miss)
        unsafe {
            __builtin_construct_at<MapEntry<K, V>>((self.entry_array() + self.len) as unsafe *u8, k, v)
            self.slot_table()[slot] = slot_word(t, self.len)
        }
        self.len += 1
    }

    /// A new entry for k, its value default-constructed; its index.
    @no_inline
    priv fn add_default(self, miss: usize, t: u32, const k: K) -> usize {
        var slot = self.place(t, miss)
        var e = self.len
        unsafe {
            __builtin_construct_at<MapEntry<K, V>>((self.entry_array() + e) as unsafe *u8, k)
            self.slot_table()[slot] = slot_word(t, e)
        }
        self.len = e + 1
        return e
    }

    /// A bigger block for at least `want` entries: the entries relocated,
    /// the slots re-placed from their tags. No key is hashed.
    @cold_path @no_inline
    priv fn grow(self, want: usize) {
        var nc = grown_cap(self.cap, want)
        var unsafe *b = block_alloc(nc, sizeof MapEntry<K, V>, alignof MapEntry<K, V>)
        var nslots = nc * 2
        var sh = shift_for(nslots)
        var ne: unsafe *MapEntry<K, V> = &null
        unsafe { ne = block_entries(b, nc) as unsafe *MapEntry<K, V> }
        if self.cap > 0 {
            rebuild(block_slots(b), nslots - 1, sh, self.slot_table(), self.cap * 2)
            var unsafe *oe = self.entry_array()
            var i: usize = 0
            while i < self.len {
                unsafe { relocate_entry((ne + i) as unsafe *u8, oe + i) }
                i += 1
            }
            block_free(self.block, self.cap, sizeof MapEntry<K, V>, alignof MapEntry<K, V>)
        }
        self.block = b
        self.cap = nc
        self.shift = sh
    }

    priv fn destroy_entries(self) {
        if __builtin_is_trivially_destructible<MapEntry<K, V>>() { return }
        var unsafe *es = self.entry_array()
        var i: usize = 0
        while i < self.len {
            unsafe { __builtin_destruct_at((es + i) as *MapEntry<K, V>) }
            i += 1
        }
    }
}
