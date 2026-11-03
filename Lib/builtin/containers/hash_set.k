/// --- The Kairo Project ------------ Lib/builtin/containers/hash_set.k --- ///
///
///   \brief The HashSet lang item: `{T}`.
///
///   \detail
///     HashMap's design with the element as the entry (hash_map.k's header
///     has the order, mutation, cost and copy rules; they hold here word for
///     word): a dense array of elements in INSERTION order plus the
///     open-addressing index of containers/hash_index.k. Iteration
///     (`for x in s`, `s.items()`, begin()..end()) is insertion order;
///     `erase` swap-removes (the last element takes the erased one's place),
///     `erase_ordered` keeps the order. No sorted order: sort where it
///     matters.
///
///     Migration from Stage 0's set: `insert(x)` returns whether x was new
///     (Stage 0's `.second`); `erase(x)` returns whether x was there;
///     iterator loops become `for x in s` or `for *p in s.items()`.
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

pub class <T impl Hash> HashSet {
    /// slots, then elements: one block (hash_index.k); never null (a
    /// dangling, aligned pointer while cap == 0: HashMap's `block` note).
    priv var block: unsafe *u8
    priv var len:   usize
    priv var cap:   usize
    priv var shift: u32

    pub inline fn HashSet(self) {
        self.block = block_empty(alignof T)
        self.len = 0
        self.cap = 0
        self.shift = 0
    }

    /// `{a, b, ...}` (ListLiteralLowering): the elements in written order; a
    /// repeated element keeps its first place.
    pub fn HashSet(self, const items: [T;]) {
        self.block = block_empty(alignof T)
        self.len = 0
        self.cap = 0
        self.shift = 0
        if items.len == 0 { return }
        self.grow(items.len)
        var i: usize = 0
        while i < items.len {
            self.insert(items.data[i])
            i += 1
        }
    }

    /// A deep copy: the same capacity, the same slots, every element copied.
    @copy
    pub fn HashSet(self, const other: Self) {
        self.block = block_empty(alignof T)
        self.len = 0
        self.cap = 0
        self.shift = other.shift
        if other.cap == 0 { return }
        var unsafe *b = block_alloc(other.cap, sizeof T, alignof T)
        unsafe { __builtin_copy(b, other.block, other.cap * 16) }
        self.block = b
        self.cap = other.cap
        var unsafe *src = other.item_array()
        var unsafe *dst = self.item_array()
        var i: usize = 0
        while i < other.len {
            unsafe { __builtin_construct_at<T>((dst + i) as unsafe *u8, src[i]) }
            i += 1
            self.len = i
        }
    }

    fn op delete(self) {
        self.destroy_items()
        block_free(self.block, self.cap, sizeof T, alignof T)
    }

    // --- size ---------------------------------------------------------------

    pub inline fn size(const self) -> usize { return self.len }
    pub inline fn empty(const self) -> bool { return self.len == 0 }
    pub inline fn capacity(const self) -> usize { return self.cap }

    // --- lookup -------------------------------------------------------------

    pub inline fn contains(const self, const x: T) -> bool { return self.index_of(x) != HASH_NPOS }

    /// The element equal to x, or end().
    pub inline fn find(self, const x: T) -> *T {
        var e = self.index_of(x)
        if e == HASH_NPOS { return self.end() }
        unsafe { return (self.item_array() + e) as *T }
    }

    // --- iteration (insertion order) -----------------------------------------

    pub inline fn begin(self) -> *T {
        unsafe { return self.item_array() as *T }
    }

    pub inline fn end(self) -> *T {
        unsafe { return (self.item_array() + self.len) as *T }
    }

    /// Every element, in order, as a view (`for *p in s.items()`: no copy).
    pub inline fn items(self) -> [T;] {
        unsafe { return Slice<T>(self.item_array() as *T, self.len) }
    }

    /// `for x in s`: each element, copied, in order.
    pub fn op in (self) -> yield T {
        var i: usize = 0
        while i < self.len {
            unsafe {
                var unsafe *p = self.item_array() + i
                yield *p
            }
            i += 1
        }
    }

    // --- insertion ------------------------------------------------------------

    /// Adds x when absent; true if it did.
    pub inline fn insert(self, const x: T) -> bool {
        var t = tag_of(x.hash())
        var slot: usize = 0
        if (self.len != 0) && (self.probe(x, t, &slot) != HASH_NPOS) { return false }
        self.add(slot, t, x)
        return true
    }

    pub fn reserve(self, n: usize) {
        if n > self.cap { self.grow(n) }
    }

    // --- removal ----------------------------------------------------------------

    /// Removes x; true if it was there. O(1): the last element moves into
    /// x's place.
    pub fn erase(self, const x: T) -> bool {
        if self.len == 0 { return false }
        var t = tag_of(x.hash())
        var slot: usize = 0
        var e = self.probe(x, t, &slot)
        if e == HASH_NPOS { return false }
        var mask = self.cap * 2 - 1
        remove_slot(self.slot_table(), mask, self.shift, slot)
        var unsafe *es = self.item_array()
        var last = self.len - 1
        unsafe { __builtin_destruct_at((es + e) as *T) }
        if e != last {
            unsafe {
                var lt = tag_of(es[last].hash())
                var ls = slot_of_entry(self.slot_table(), mask, self.shift, lt, last)
                relocate_entry((es + e) as unsafe *u8, es + last)
                self.slot_table()[ls] = slot_word(lt, e)
            }
        }
        self.len = last
        return true
    }

    /// Removes x keeping the others' order; true if it was there. O(len).
    pub fn erase_ordered(self, const x: T) -> bool {
        if self.len == 0 { return false }
        var t = tag_of(x.hash())
        var slot: usize = 0
        var e = self.probe(x, t, &slot)
        if e == HASH_NPOS { return false }
        remove_slot(self.slot_table(), self.cap * 2 - 1, self.shift, slot)
        var unsafe *es = self.item_array()
        unsafe { __builtin_destruct_at((es + e) as *T) }
        var i = e
        while i + 1 < self.len {
            unsafe { relocate_entry((es + i) as unsafe *u8, es + (i + 1)) }
            i += 1
        }
        shift_down_after(self.slot_table(), self.cap * 2, e)
        self.len -= 1
        return true
    }

    /// Removes every element; keeps the capacity.
    pub fn clear(self) {
        if self.cap == 0 { return }
        self.destroy_items()
        self.len = 0
        unsafe { __builtin_set_mem(self.block, 0 as byte, self.cap * 16) }
    }

    // --- internals ----------------------------------------------------------------

    priv inline fn slot_table(const self) -> unsafe *u64 { return block_slots(self.block) }

    priv inline fn item_array(const self) -> unsafe *T {
        unsafe { return block_entries(self.block, self.cap) as unsafe *T }
    }

    priv inline fn index_of(const self, const x: T) -> usize {
        if self.len == 0 { return HASH_NPOS }
        var slot: usize = 0
        return self.probe(x, tag_of(x.hash()), &slot)
    }

    /// HashMap::probe: x's index, or HASH_NPOS and the empty slot. len > 0.
    priv inline fn probe(const self, const x: T, t: u32, slot: *usize) -> usize {
        var mask = self.cap * 2 - 1
        var i = (t >> self.shift) as usize
        var unsafe *ss = self.slot_table()
        var unsafe *es = self.item_array()
        unsafe {
            while true {
                var s = ss[i]
                if s == 0 { break }
                if slot_tag(s) == t {
                    var e = slot_entry(s)
                    // `es[e]`, not `*(es + e)`: a dereference as an operand
                    // of `==` on a T is emitted as C++'s own `==`, not the
                    // bound's witness (a compiler bug; TICKETS).
                    if es[e] == x { (*slot) = i; return e }
                }
                i = (i + 1) & mask
            }
        }
        (*slot) = i
        return HASH_NPOS
    }

    /// HashMap::place.
    priv inline fn place(self, t: u32, slot: usize) -> usize {
        if self.len == self.cap {
            self.grow(self.len + 1)
            return empty_slot(self.slot_table(), self.cap * 2 - 1, self.shift, t)
        }
        if self.len == 0 { return (t >> self.shift) as usize }
        return slot
    }

    /// A new element x at the end, named by `slot`.
    @no_inline
    priv fn add(self, miss: usize, t: u32, const x: T) {
        var slot = self.place(t, miss)
        unsafe {
            __builtin_construct_at<T>((self.item_array() + self.len) as unsafe *u8, x)
            self.slot_table()[slot] = slot_word(t, self.len)
        }
        self.len += 1
    }

    @cold_path @no_inline
    priv fn grow(self, want: usize) {
        var nc = grown_cap(self.cap, want)
        var unsafe *b = block_alloc(nc, sizeof T, alignof T)
        var nslots = nc * 2
        var sh = shift_for(nslots)
        var ne: unsafe *T = &null
        unsafe { ne = block_entries(b, nc) as unsafe *T }
        if self.cap > 0 {
            rebuild(block_slots(b), nslots - 1, sh, self.slot_table(), self.cap * 2)
            var unsafe *oe = self.item_array()
            var i: usize = 0
            while i < self.len {
                unsafe { relocate_entry((ne + i) as unsafe *u8, oe + i) }
                i += 1
            }
            block_free(self.block, self.cap, sizeof T, alignof T)
        }
        self.block = b
        self.cap = nc
        self.shift = sh
    }

    priv fn destroy_items(self) {
        if __builtin_is_trivially_destructible<T>() { return }
        var unsafe *es = self.item_array()
        var i: usize = 0
        while i < self.len {
            unsafe { __builtin_destruct_at((es + i) as *T) }
            i += 1
        }
    }
}
