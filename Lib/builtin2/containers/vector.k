/// builtin/containers/vector.k

import alloc_raw::{
    alloc_raw,
    free_raw,
    oom,
}
import base::cmp::*
import base::copy::*
import base::intrinsics::*
import base::iter::*
import base::range::*
import builtin::Null
import containers::slice::*

// Growth for relocatable elements: byte-level, one copy for every `T`.
// Returns the new buffer; the header in front of it holds the new cap.
eval if defined!(__x86_64__) || defined!(__aarch64__) {
    @cold_path @preserve_most @no_inline
    priv fn grow_bytes(buf:        *u8?,
                       len:        usize,
                       need:       usize,
                       elem_size:  usize,
                       elem_align: usize) -> *u8 {
        __builtin_trap() // BODY-TODO
    }
} else {
    @cold_path @no_inline
    priv fn grow_bytes(buf:        *u8?,
                       len:        usize,
                       need:       usize,
                       elem_size:  usize,
                       elem_align: usize) -> *u8 {
        __builtin_trap() // BODY-TODO
    }
}

/// Two words, the same two as a `Slice<T>`: the conversion to a slice is a
/// reinterpretation. `[cap: usize]` sits just before element 0, padded to
/// `T`'s alignment. An empty vector points at a shared header with cap 0,
/// so push needs no null check (an over-aligned `T` uses null instead).
/// Slice members are reached through the one-hop lookup rule: `v.sort()`.
/// MOVE-ONLY: `copy()` duplicates. A literal `[a, b]` moves its temporaries in.
@relocatable
pub class <T> Vector {
    priv var buf: *T?
    priv var len: usize

    pub fn Vector(self) {
        // BODY-MIN
        self.buf = null
        self.len = 0
    }

    pub fn <R impl ElemRange<T>> Vector(self, const r: R) requires T impl Copyable { // copies r.size() elements from r.data(); names no C++ type
        __builtin_trap() // BODY-TODO
    }

    @move pub fn Vector(self, other: Self) { // bitwise; other becomes empty
        // BODY-MIN
        unsafe {
            *(&self.buf as unsafe *usize) = *(&other.buf as unsafe *const usize)
        }

        self.len  = other.len
        other.buf = null
        other.len = 0
    }

    pub fn op finally(self) {
        // BODY-MIN
        var unsafe *b = self.raw_()
        if b == &null {
            return
        }

        if !__builtin_is_trivially_destructible<T>() {
            for var i: usize = 0; i < self.len; ++i {
                unsafe {
                    __builtin_destruct_at(&b[i])
                }
            }
        }

        var hdr = Vector<T>::hdr_()
        unsafe {
            free_raw(
                (b as usize as unsafe *u8) - hdr,
                hdr + self.cap_() * sizeof T,
                Vector<T>::align_(),
            )
        }
    }

    // A slice of a temporary vector dies with the statement. Until Tether.
    @implicit pub fn op as (const self) -> [const T;] {
        // BODY-MIN
        unsafe {
            return Slice<const T>(self.raw_() as unsafe *const T, self.len)
        }
    }

    @implicit pub fn op as (self) -> [T;] {
        // BODY-MIN
        return Slice<T>(self.raw_(), self.len)
    }

    @hot_path pub fn op []  (const self, i: usize) -> *const T { // traps
        // BODY-MIN
        if i >= self.len {
            index_fail(i, self.len)
        }

        unsafe {
            return (self.raw_() + i) as unsafe *const T as *const T
        }
    }

    @hot_path pub fn op []= (self, i: usize) -> *T { // traps
        // BODY-MIN
        if i >= self.len {
            index_fail(i, self.len)
        }

        unsafe {
            return (self.raw_() + i) as *T
        }
    }

    pub fn op []  (const self, r: Range<usize>) -> [const T;] {
        __builtin_trap() // BODY-TODO
    }

    pub fn op []= (self, r: Range<usize>) -> [T;] {
        __builtin_trap() // BODY-TODO
    }

    pub fn op []  (const self, r: RangeFrom<usize>) -> [const T;] {
        __builtin_trap() // BODY-TODO
    }

    pub fn op []= (self, r: RangeFrom<usize>) -> [T;] {
        __builtin_trap() // BODY-TODO
    }

    pub fn op []  (const self, r: RangeTo<usize>) -> [const T;] {
        __builtin_trap() // BODY-TODO
    }

    pub fn op []= (self, r: RangeTo<usize>) -> [T;] {
        __builtin_trap() // BODY-TODO
    }

    pub fn op in (self) -> yield *T {
        // BODY-MIN
        var i: usize = 0
        while i < self.len {
            unsafe {
                yield (self.raw_() + i) as *T
            }

            i += 1
        }
    }

    pub fn op in (const self) -> yield *const T {
        // BODY-MIN
        var i: usize = 0
        while i < self.len {
            unsafe {
                yield (self.raw_() + i) as unsafe *const T as *const T
            }

            i += 1
        }
    }

    // BODY-MIN: the funnel. An empty vector that never allocated holds null;
    // the shared empty header is not used yet.
    priv inline fn raw_(const self) -> unsafe *T {
        unsafe {
            return (*(&self.buf as unsafe *const usize)) as unsafe *T
        }
    }

    // Bytes in front of element 0: the capacity word, padded to T's alignment.
    priv static inline fn hdr_() -> usize {
        return if alignof T > sizeof usize => alignof T else => sizeof usize
    }

    priv static inline fn align_() -> usize {
        return if alignof T > alignof usize => alignof T else => alignof usize
    }

    priv inline fn cap_(const self) -> usize {
        var unsafe *b = self.raw_()
        if b == &null {
            return 0
        }

        unsafe {
            return *((b as usize as unsafe *const usize) - 1)
        }
    }

    // BODY-MIN: a new block with room for at least `need`; the elements are
    // relocated by their bytes (elements that are not relocatable: grow_moving).
    priv fn grow_(self, need: usize) {
        var old = self.cap_()
        var cap = old * 2
        if cap < need {
            cap = need
        }

        if cap < 4 {
            cap = 4
        }

        var        hdr   = Vector<T>::hdr_()
        var        al    = Vector<T>::align_()
        var        bytes = hdr + cap * sizeof T
        var unsafe *blk  = alloc_raw(bytes, al)
        if blk == &null {
            oom(bytes, al)
        }

        unsafe {
            var unsafe *nb = blk + hdr
            *((nb as unsafe *usize) - 1) = cap
            var unsafe *ob = self.raw_() as usize as unsafe *u8
            if ob != &null {
                __builtin_copy(nb, ob as unsafe *const u8, self.len * sizeof T)
                free_raw(ob - hdr, hdr + old * sizeof T, al)
            }

            self.buf = nb as unsafe *T as *T
        }
    }

    @cold_path @no_inline
    priv fn grow_moving(self, need: usize) { // elements that are not relocatable
        __builtin_trap() // BODY-TODO
    }
}

extend <T> Vector<T> {
    pub static fn with_capacity(n: usize) -> [T] {
        __builtin_trap() // BODY-TODO
    }

    pub fn size(const self) -> usize {
        // BODY-MIN
        return self.len
    }

    pub fn is_empty(const self) -> bool {
        // BODY-MIN
        return self.len == 0
    }

    pub fn capacity(const self) -> usize {
        // BODY-MIN
        return self.cap_()
    }

    pub fn reserve(self, n: usize) {
        // BODY-MIN
        if n > self.cap_() {
            self.grow_(n)
        }
    }

    pub fn shrink_to_fit(self) {
        __builtin_trap() // BODY-TODO
    }

    @hot_path pub fn push(self, v: T) {
        // BODY-MIN
        if self.len == self.cap_() {
            self.grow_(self.len + 1)
        }

        unsafe {
            __builtin_construct_at<T>(
                (self.raw_() + self.len) as usize as unsafe *u8,
                v,
            )
        }

        self.len += 1
    }

    pub fn pop(self) -> T? {
        __builtin_trap() // BODY-TODO
    }

    pub fn insert(self, i: usize, v: T) {
        __builtin_trap() // BODY-TODO
    }

    pub fn remove(self, i: usize) -> T { // traps
        __builtin_trap() // BODY-TODO
    }

    pub fn swap_remove(self, i: usize) -> T { // traps
        __builtin_trap() // BODY-TODO
    }

    pub fn drain(self, r: Range<usize>) -> Drain<T> {
        __builtin_trap() // BODY-TODO
    }

    pub fn append(self, other: [T]) { // consumes other
        __builtin_trap() // BODY-TODO
    }

    pub fn retain(self, keep: fn(*const T) -> bool) {
        __builtin_trap() // BODY-TODO
    }

    pub fn truncate(self, n: usize) {
        __builtin_trap() // BODY-TODO
    }

    pub fn clear(self) {
        __builtin_trap() // BODY-TODO
    }
}

extend <T impl Default> Vector<T> {
    pub static fn with_len(n: usize) -> [T] {
        __builtin_trap() // BODY-TODO
    }

    pub fn resize(self, n: usize) {
        __builtin_trap() // BODY-TODO
    }
}

extend <T impl Copyable> Vector<T> {
    pub fn copy(const self) -> Self { // deep
        __builtin_trap() // BODY-TODO
    }

    pub static fn filled(n: usize, const v: T) -> [T] {
        __builtin_trap() // BODY-TODO
    }

    pub static fn from_slice(const items: [const T;]) -> [T] {
        __builtin_trap() // BODY-TODO
    }

    pub fn resize(self, n: usize, const v: T) { // overloads resize(self, n) in the Default extend
        __builtin_trap() // BODY-TODO
    }

    pub fn extend_from(self, const items: [const T;]) {
        __builtin_trap() // BODY-TODO
    }
}

extend <T impl Eq> Vector<T> {
    pub fn dedup(self) {
        __builtin_trap() // BODY-TODO
    }
}

extend <T> Vector<T> impl FromIterator<T> {
    static fn <J impl Iterator> from_iter(it:   J,
                                          hint: usize) -> Self requires __builtin_is_same<J::Item, T>() {
        __builtin_trap() // BODY-TODO
    }
}

/// Move-only: it points into the vector and closes the gap when it ends,
/// so a copy would close it twice.
pub class <T> Drain {
    priv var vec:  *Vector<T>
    priv var head: usize
    priv var tail: usize
    priv var end:  usize

    @move pub fn Drain(self, other: Self) {
        __builtin_trap() // BODY-TODO
    }

    pub fn op finally(self) { // drops the rest, closes the gap
        __builtin_trap() // BODY-TODO
    }
}

extend <T> Drain<T> impl DoubleEnded {
    type Item = T
    fn next(self) -> T? {
        __builtin_trap() // BODY-TODO
    }

    fn next_back(self) -> T? {
        __builtin_trap() // BODY-TODO
    }
}

extend <T> Drain<T> impl ExactSize {
    fn remaining(const self) -> usize {
        __builtin_trap() // BODY-TODO
    }
}
