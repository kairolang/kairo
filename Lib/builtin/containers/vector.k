/// --- The Kairo Project -------------- Lib/builtin/containers/vector.k --- ///
///
///   The Vector lang item: `[T]`. Growable, owning, contiguous. Imports Slice
///   so `[T;]` in its constructor resolves: a builtin file's lang items are
///   bound before its types are resolved, in import order
///   (NameResolution::fill_lang_items).
///
///   \par Ownership
///     [0, len) are live Ts in cap slots from the allocator in effect
///     (alloc.k's non-_in family). Every slot is constructed in place and
///     destroyed exactly once: on pop / erase / clear / resize down, or by
///     the destructor. An empty vector with no storage holds
///     dangling(alignof T), never &null, so `data()` and the `[T;]` view are
///     always valid pointers.
///
///   \par COPY
///     A copy is a deep copy. The @copy constructor is constrained on T
///     being copyable, so `[MoveOnly]` has no copy (C++ drops the
///     constructor from the instance and InterfaceEmitter constrains the
///     derived `op =` the same way). Kairo cannot say "COPY iff T is COPY"
///     (ClassLifecycle reads a declared @copy as COPY whatever T is), and a
///     class declares one transfer constructor (SC057E), so there is no
///     cheap move: moving a vector copies it, and `[MoveOnly]` is neither
///     copied nor moved -- build it in place and pass it by reference.
///
///   \par Constrained members
///     Every home of an instance writes `template class Vector<X>;`, which
///     instantiates each non-template member. So each member that copies or
///     default-constructs a T carries a requires-clause, and C++ leaves it
///     out of an instance whose T cannot (CXXSpell::member_requires): a
///     `[MoveOnly]` has no copy, no `Vector(n)` and no `resize(n, value)`,
///     and has every other member.
///
///   \par Element transfer
///     Growth, insert and erase RELOCATE: the element is move-constructed
///     into its new slot and the old one destroyed, so a MOVE T is never
///     copied. A trivially relocatable T is moved as bytes.
///
///   \par Hot paths
///     `[]` is one compare and a load (the trap is cold); size / empty /
///     data / begin / end / back are loads; push_back with spare capacity
///     makes no call. Growth and the element-wise slow paths are out of line.
///
///   Members are in this file, not in std: a record's members are one
///   declaration (README, "Where a new API goes"), and `extend` cannot add
///   constructors, `op []` or `op as`, nor extend a type from another file
///   (extends.mdx, "Same-File Restriction").
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import containers::slice::*
import base::intrinsics::*
import base::alloc::*

/// Move-constructs a T at dst from src. The `@move` parameter is what makes
/// the caller's `buf[i]` an xvalue: Kairo has no std::move.
inline fn <T> vector_move_into(dst: unsafe *u8, @move src: T) {
    __builtin_construct_at<T>(dst, src)
}

/// Out of line and cold: what an out-of-range `[]`, `front`, `back` or
/// `pop_back` runs.
@cold_path @no_inline
fn vector_out_of_range() -> ! {
    __builtin_trap()
}

/// Growable, owning, contiguous array. `[T]` desugars to `Vector<T>`, and the list literal
/// `[a, b, c]` against a `[T]` target builds one.
///
/// Elements live in one heap block from the allocator in effect. Indexing, `front`, `back` and
/// `pop_back` check bounds and trap (see \panics on each); growth is geometric (twice the
/// capacity, at least 4), so `push_back` is O(1) amortized. A copy is a deep copy; a `[MoveOnly]`
/// has no copy and no `Vector(n)` / `resize(n, value)` (those members need T to be copyable /
/// default-constructible).
///
/// References and pointers into a vector (`v[i]`, `begin()`, `data()`) are invalidated by any
/// operation that grows, inserts, erases or clears.
///
/// \see Slice
/// \example
/// ```kairo
/// var v: [i32] = [1, 2, 3]
/// v.push(4)
/// var sum: i32 = 0
/// for x in v { sum += x }
/// ```
pub class <T> Vector {
    var buf: *T
    var len: usize
    var cap: usize

    /// Empty, no storage.
    /// Creates an empty vector. Allocates nothing; `capacity()` is 0.
    pub inline fn Vector(self) {
        self.set_empty()
    }

    /// Creates a vector holding a copy of every element of `items`.
    ///
    /// This is what `[a, b, c]` lowers to against a `[T]` target, and what `s as [T]` calls. O(n).
    pub fn Vector(self, const items: [T;]) requires __builtin_is_constructible<T, const T>() {
        self.set_empty()
        if items.len == 0 { return }
        self.allocate(items.len)
        self.copy_from(items.data, items.len)
    }

    /// Creates a vector of `n` default-constructed elements, with capacity exactly `n`. O(n).
    ///
    /// Only available when T is default-constructible.
    pub fn Vector(self, n: usize) requires __builtin_is_default_constructible<T>() {
        self.set_empty()
        if n == 0 { return }
        self.allocate(n)
        while self.len < n {
            __builtin_construct_at<T>(self.slot(self.len))
            self.len += 1
        }
    }

    /// A deep copy, with capacity for exactly other's elements.
    ///
    /// The one transfer constructor a class may declare today (SC057E). If
    /// a COPY class may also declare a cheap move, it is this, beside it:
    ///     @move pub inline fn Vector(self, other: Self) {
    ///         self.buf = other.buf; self.len = other.len; self.cap = other.cap
    ///         other.set_empty()
    ///     }
    /// Nothing else changes: the destructor frees an empty vector's
    /// storage as a no-op (cap 0), and `op =` is derived per constructor.
    @copy
    pub fn Vector(self, const other: Self) requires __builtin_is_constructible<T, const T>() {
        self.set_empty()
        if other.len == 0 { return }
        self.allocate(other.len)
        self.copy_from(other.buf, other.len)
    }

    fn op delete(self) {
        self.destroy_range(0, self.len)
        free_raw(self.storage(), self.cap * sizeof T, alignof T)
    }

    /// A vector passes where a slice is wanted: a view, nothing copied.
    @implicit pub inline fn op as (const self) -> [T;] {
        return Slice<T>(self.buf, self.len)
    }

    // --- access ------------------------------------------------------------

    /// Returns the element at index `i` as a place, so `v[i] = x` assigns.
    ///
    /// \panics when `i >= size()` (traps; no message).
    pub inline fn op [] (self, i: usize) -> *T {
        @unlikely if i >= self.len { vector_out_of_range() }
        return &self.buf[i]
    }

    /// Returns the element at index `i` through a const vector.
    ///
    /// \panics when `i >= size()` (traps; no message).
    pub inline fn op [] (const self, i: usize) -> *const T {
        @unlikely if i >= self.len { vector_out_of_range() }
        return &self.buf[i]
    }

    /// Returns the number of live elements. O(1).
    pub inline fn size(const self) -> usize { return self.len }
    /// Returns true when the vector holds no elements. O(1).
    pub inline fn empty(const self) -> bool { return self.len == 0 }
    /// Returns how many elements fit before the next reallocation. O(1).
    pub inline fn capacity(const self) -> usize { return self.cap }

    /// Returns a pointer to the first element (never null: a dangling, aligned pointer while the
    /// vector has no storage).
    ///
    /// One accessor for const and mutable receivers alike: it returns a mutable `*T` even from a
    /// `const self`.
    pub inline fn data(const self) -> *T { return self.buf }

    /// Returns a pointer to the first element; equal to `end()` when empty.
    ///
    /// Together with `end()` this is the pointer pair `insert` / `erase` positions are spelled in.
    pub inline fn begin(const self) -> *T { return self.buf }
    /// Returns a pointer one past the last element. Not dereferenceable.
    pub inline fn end(const self) -> *T { return &self.buf[self.len] }

    /// Returns a pointer to the first element.
    ///
    /// \panics when the vector is empty (traps).
    pub inline fn front(const self) -> *T {
        @unlikely if self.len == 0 { vector_out_of_range() }
        return &self.buf[0]
    }
    /// Returns a pointer to the last element.
    ///
    /// \panics when the vector is empty (traps).
    pub inline fn back(const self) -> *T {
        @unlikely if self.len == 0 { vector_out_of_range() }
        return &self.buf[self.len - 1]
    }

    /// Iterates the elements in order: `for x in v` / `for *x in v`.
    ///
    /// `for x in v` binds each element as a value; `for *x in v` binds a pointer to the element
    /// itself, so it can be modified. Do not grow or erase while iterating.
    pub fn op in (const self) -> yield T {
        var i: usize = 0
        while i < self.len {
            yield self.buf[i]
            i += 1
        }
    }

    // --- adding ------------------------------------------------------------

    /// Appends `v` to the end. O(1) amortized; reallocates when full.
    ///
    /// `v` is taken by value, so it stays valid across the growth (`v.push_back(v[0])` is fine).
    /// A copyable lvalue is copied, a MOVE value is moved.
    pub inline fn push_back(self, v: T) {
        @unlikely if self.len == self.cap { self.push_grow(v); return }
        __builtin_construct_at<T>(self.slot(self.len), v)
        self.len += 1
    }

    /// push_back under the name collections.mdx documents.
    /// Appends `v` to the end; the name `collections` documents for `push_back`. Same cost.
    pub inline fn push(self, v: T) {
        @unlikely if self.len == self.cap { self.push_grow(v); return }
        __builtin_construct_at<T>(self.slot(self.len), v)
        self.len += 1
    }

    /// Appends a T constructed in place from `args` and returns a pointer to it. O(1) amortized.
    ///
    /// On growth the new element is built in the new block before the old ones move, so an argument
    /// that refers into this vector is still valid when read.
    pub inline fn <...A> emplace_back(self, ...args: A) -> *T {
        @unlikely if self.len == self.cap { return self.emplace_grow(args...) }
        var p: *T = __builtin_construct_at<T>(self.slot(self.len), args...)
        self.len += 1
        return p
    }

    /// Inserts `v` before `pos` and returns a pointer to the new element. O(n): later elements
    /// shift up one slot.
    ///
    /// \param pos  a pointer in `[begin(), end()]`; `end()` appends.
    /// \panics when `pos` is outside that range (traps).
    pub fn insert(self, pos: *T, v: T) -> *T {
        var at = self.index_of(pos)
        if at > self.len { vector_out_of_range() }
        if self.len == self.cap { self.grow(self.len + 1) }
        var k = self.len
        if __builtin_is_trivially_relocatable<T>() {
            __builtin_move_mem(self.slot(at + 1), self.slot(at), (k - at) * sizeof T)
        } else {
            while k > at {
                vector_move_into<T>(self.slot(k), self.buf[k - 1])
                __builtin_destruct_at(&self.buf[k - 1])
                k -= 1
            }
        }
        var p: *T = __builtin_construct_at<T>(self.slot(at), v)
        self.len += 1
        return p
    }

    // --- removing ----------------------------------------------------------

    /// Destroys the last element. O(1).
    ///
    /// \panics when the vector is empty (traps).
    pub inline fn pop_back(self) {
        @unlikely if self.len == 0 { vector_out_of_range() }
        self.len -= 1
        if !__builtin_is_trivially_destructible<T>() { __builtin_destruct_at(&self.buf[self.len]) }
    }

    /// Destroys every element and sets the size to 0. Keeps the storage. O(n), O(1) for trivial T.
    pub inline fn clear(self) {
        if !__builtin_is_trivially_destructible<T>() { self.destroy_range(0, self.len) }
        self.len = 0
    }

    /// Removes the element at `pos` and returns a pointer to the element that followed it (now at
    /// `pos`). O(n): later elements shift down one slot.
    ///
    /// \panics when `pos` is not in `[begin(), end())` (traps).
    pub fn erase(self, pos: *T) -> *T {
        var at = self.index_of(pos)
        if at >= self.len { vector_out_of_range() }
        return self.erase_range(at, at + 1)
    }

    /// Removes the elements in `[first, last)` and returns a pointer to the element that followed
    /// them. O(n). An empty range removes nothing.
    ///
    /// \panics when `first > last` or `last > end()` (traps).
    pub fn erase(self, first: *T, last: *T) -> *T {
        var lo = self.index_of(first)
        var hi = self.index_of(last)
        if (lo > hi) || (hi > self.len) { vector_out_of_range() }
        return self.erase_range(lo, hi)
    }

    // --- capacity ----------------------------------------------------------

    /// Ensures capacity for at least `n` elements. Never shrinks. O(size()) when it reallocates.
    pub inline fn reserve(self, n: usize) {
        if n > self.cap { self.reallocate(n) }
    }

    /// Resizes to `n` elements: destroys the tail, or appends default-constructed elements.
    ///
    /// Only available when T is default-constructible. O(|n - size()|).
    pub fn resize(self, n: usize) requires __builtin_is_default_constructible<T>() {
        if n <= self.len {
            if !__builtin_is_trivially_destructible<T>() { self.destroy_range(n, self.len) }
            self.len = n
            return
        }
        if n > self.cap { self.grow(n) }
        while self.len < n {
            __builtin_construct_at<T>(self.slot(self.len))
            self.len += 1
        }
    }

    /// Resizes to `n` elements: destroys the tail, or appends copies of `value`.
    ///
    /// `value` may be an element of this vector. Only available when T is copyable.
    pub fn resize(self, n: usize, const value: T) requires __builtin_is_constructible<T, const T>() {
        if n <= self.len {
            if !__builtin_is_trivially_destructible<T>() { self.destroy_range(n, self.len) }
            self.len = n
            return
        }
        // value may be one of ours: copy it before the storage moves. Read
        // through a pointer: each construction copies, and a by-name use
        // in a loop is a move to MoveCheck, which checks this body for
        // every instance, `[MoveOnly]` (constrained out in C++) included.
        var keep = value
        var *src = &keep
        if n > self.cap { self.grow(n) }
        while self.len < n {
            __builtin_construct_at<T>(self.slot(self.len), *src)
            self.len += 1
        }
    }

    // --- internals ---------------------------------------------------------

    /// No elements, no storage: what every constructor starts from and what
    /// a moved-from vector would be left as.
    priv inline fn set_empty(self) {
        unsafe { self.buf = dangling(alignof T) as unsafe *T as *T }
        self.len = 0
        self.cap = 0
    }

    priv inline fn storage(const self) -> unsafe *u8 {
        unsafe { return self.buf as unsafe *u8 }
    }

    priv inline fn slot(const self, i: usize) -> unsafe *u8 {
        unsafe { return (self.buf as unsafe *u8) + i * sizeof T }
    }

    priv inline fn index_of(const self, p: *const T) -> usize {
        unsafe { return ((p as usize) - (self.buf as usize)) / sizeof T }
    }

    /// n * sizeof T, or the OOM hook when that overflows.
    priv inline fn bytes_for(const self, n: usize) -> usize {
        @unlikely if n > (~0usize) / sizeof T { oom(~0usize, alignof T) }
        return n * sizeof T
    }

    /// Storage for n on an empty vector with none.
    priv fn allocate(self, n: usize) {
        var bytes = self.bytes_for(n)
        var unsafe *p = alloc_raw(bytes, alignof T)
        @unlikely if p == &null { oom(bytes, alignof T) }
        unsafe { self.buf = p as unsafe *T as *T }
        self.cap = n
    }

    /// Copy-constructs n elements from src after the live ones.
    priv fn copy_from(self, src: *const T, n: usize) requires __builtin_is_constructible<T, const T>() {
        if __builtin_is_trivially_copyable<T>() {
            unsafe { __builtin_copy(self.slot(self.len), src as unsafe *const u8, n * sizeof T) }
            self.len += n
            return
        }
        var i: usize = 0
        while i < n {
            __builtin_construct_at<T>(self.slot(self.len), src[i])
            self.len += 1
            i += 1
        }
    }

    /// Destroys [lo, hi), first to last.
    priv fn destroy_range(self, lo: usize, hi: usize) {
        if __builtin_is_trivially_destructible<T>() { return }
        var i = lo
        while i < hi {
            __builtin_destruct_at(&self.buf[i])
            i += 1
        }
    }

    /// Relocates [lo, hi) of this vector to dst, slot by slot, first to
    /// last: correct for a new buffer and for a move down within this one.
    priv fn relocate_to(self, dst: unsafe *u8, lo: usize, hi: usize) {
        if __builtin_is_trivially_relocatable<T>() {
            __builtin_move_mem(dst, self.slot(lo), (hi - lo) * sizeof T)
            return
        }
        var i = lo
        var unsafe *d = dst
        while i < hi {
            vector_move_into<T>(d, self.buf[i])
            __builtin_destruct_at(&self.buf[i])
            unsafe { d = d + sizeof T }
            i += 1
        }
    }

    /// Geometric: twice the capacity, at least need, at least 4.
    priv inline fn next_cap(const self, need: usize) -> usize {
        var c = self.cap * 2
        if c < need { c = need }
        if c < 4 { c = 4 }
        return c
    }

    @cold_path @no_inline
    priv fn grow(self, need: usize) {
        self.reallocate(self.next_cap(need))
    }

    /// Capacity exactly n (n >= len). A trivially relocatable T resizes the
    /// block (the allocator may extend it, or move it as bytes); anything
    /// else gets a new block and each element relocated into it.
    @no_inline
    priv fn reallocate(self, n: usize) {
        var bytes = self.bytes_for(n)
        var old = self.cap * sizeof T
        if __builtin_is_trivially_relocatable<T>() {
            var unsafe *q = resize_raw(self.storage(), old, bytes, alignof T)
            @unlikely if q == &null { oom(bytes, alignof T) }
            unsafe { self.buf = q as unsafe *T as *T }
            self.cap = n
            return
        }
        var unsafe *p = alloc_raw(bytes, alignof T)
        @unlikely if p == &null { oom(bytes, alignof T) }
        self.relocate_to(p, 0, self.len)
        free_raw(self.storage(), old, alignof T)
        unsafe { self.buf = p as unsafe *T as *T }
        self.cap = n
    }

    /// push_back's full case, whole, so the fast path is a tail call away
    /// from it and keeps no registers or frame of its own.
    @cold_path @no_inline
    priv fn push_grow(self, v: T) {
        self.reallocate(self.next_cap(self.len + 1))
        __builtin_construct_at<T>(self.slot(self.len), v)
        self.len += 1
    }

    /// emplace_back's full case: the new element is built in the new block
    /// first, while args may still point into the old one.
    @cold_path @no_inline
    priv fn <...A> emplace_grow(self, ...args: A) -> *T {
        var n = self.next_cap(self.len + 1)
        var bytes = self.bytes_for(n)
        var unsafe *p = alloc_raw(bytes, alignof T)
        @unlikely if p == &null { oom(bytes, alignof T) }
        var e: *T = __builtin_construct_at<T>(p + self.len * sizeof T, args...)
        self.relocate_to(p, 0, self.len)
        free_raw(self.storage(), self.cap * sizeof T, alignof T)
        unsafe { self.buf = p as unsafe *T as *T }
        self.cap = n
        self.len += 1
        return e
    }

    /// Destroys [lo, hi) and moves the tail down over it.
    priv fn erase_range(self, lo: usize, hi: usize) -> *T {
        if lo == hi { return &self.buf[lo] }
        self.destroy_range(lo, hi)
        self.relocate_to(self.slot(lo), hi, self.len)
        self.len -= hi - lo
        return &self.buf[lo]
    }
}
