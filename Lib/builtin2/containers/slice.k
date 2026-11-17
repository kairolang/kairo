/// builtin/containers/slice.k

ffi "c" import "rt/crash.h"

import alloc_raw::{
    alloc_raw,
    free_raw,
    oom,
}
import base::cmp::*
import base::copy::*
import base::intrinsics::*
import base::range::*
import builtin::Null
import containers::vector::*
import string::*

/// Callbacks are `fn` values: one indirect call per element, no inlining.
/// Fine for most code; a callable-interface bound will replace them later.

// --- failure ----------------------------------------------------------------

// The failure functions format into a stack buffer and hand it to the
// runtime's crash sink, which writes it and aborts. Nothing here allocates
// or reaches formatted I/O.

priv eval FAIL_BUF: usize = 112

priv fn fail_text(buf: unsafe *u8, at: usize, const s: string) -> usize {
    var n = s.size()
    if at + n > FAIL_BUF {
        return at
    }

    unsafe {
        var unsafe *src = s.data() as unsafe *const u8
        var i: usize = 0
        while i < n {
            buf[at + i] = src[i]
            i += 1
        }
    }

    return at + n
}

priv fn fail_byte(buf: unsafe *u8, at: usize, b: u8) -> usize {
    if at >= FAIL_BUF {
        return at
    }

    unsafe {
        buf[at] = b
    }

    return at + 1
}

priv fn fail_num(buf: unsafe *u8, at: usize, v: usize) -> usize {
    var digits: [u8; 24]
    var k: usize = 0
    var x = v
    loop {
        digits[k] = ('0' as u8) + (x % 10) as u8
        k += 1
        x /= 10
        if x == 0 {
            break
        }
    }

    if at + k > FAIL_BUF {
        return at
    }

    var out = at
    unsafe {
        while k > 0 {
            k -= 1
            buf[out] = digits[k]
            out += 1
        }
    }

    return out
}

/// One copy for every element type.
@cold_path @no_inline
prot fn index_fail(i: usize, len: usize) -> ! {
    var buf: [u8; FAIL_BUF]
    unsafe {
        var unsafe *b = &buf[0] as unsafe *u8
        var at        = fail_text(b, 0, "index")
        at = fail_byte(b, at, ' ' as u8)
        at = fail_num(b, at, i)
        at = fail_text(b, at, " is out of bounds for length ")
        at = fail_num(b, at, len)
        kairo_rt_crash(b as unsafe *const u8, at)
    }
}

@cold_path @no_inline
prot fn range_fail(lo: usize, hi: usize, len: usize) -> ! {
    var buf: [u8; FAIL_BUF]
    unsafe {
        var unsafe *b = &buf[0] as unsafe *u8
        var at        = fail_text(b, 0, "range")
        at = fail_byte(b, at, ' ' as u8)
        at = fail_num(b, at, lo)
        at = fail_text(b, at, "..")
        at = fail_num(b, at, hi)
        at = fail_text(b, at, " is out of bounds for length ")
        at = fail_num(b, at, len)
        kairo_rt_crash(b as unsafe *const u8, at)
    }
}

// --- range bounds -----------------------------------------------------------

// Each returns the exclusive end of the range inside `len` elements, or
// traps; the begin is then at most the end.

/// The exclusive end of `..=hi` for a message; `hi` itself when that has
/// no successor.
priv fn range_inclusive_end(hi: usize) -> usize {
    if hi == usize::MAX {
        return hi
    }

    return hi + 1
}

priv inline fn range_end(const r: Range<usize>, len: usize) -> usize {
    var hi = r.end
    if r.inclusive {
        @unlikely if hi >= len {
            range_fail(r.begin, range_inclusive_end(hi), len)
        }

        hi += 1
    }

    @unlikely if r.begin > hi || hi > len {
        range_fail(r.begin, hi, len)
    }

    return hi
}

priv inline fn range_from_begin(const r: RangeFrom<usize>, len: usize) -> usize {
    @unlikely if r.begin > len {
        range_fail(r.begin, len, len)
    }

    return r.begin
}

priv inline fn range_to_end(const r: RangeTo<usize>, len: usize) -> usize {
    var hi = r.end
    if r.inclusive {
        @unlikely if hi >= len {
            range_fail(0, range_inclusive_end(hi), len)
        }

        hi += 1
    }

    @unlikely if hi > len {
        range_fail(0, hi, len)
    }

    return hi
}

/// A view: copied freely, owns nothing. Two words. Reads through op [],
/// writes through op []=.
pub class <T> Slice {
    // Invariant: `ptr` is null only when `len` is 0. A non-null `ptr` with
    // `len` 0 is the empty tail of a split. `[ptr, ptr + len)` are live
    // elements.
    priv var ptr: *T?   // null only when len == 0
    priv var len: usize

    /// What a `for x in s` loop reads; nothing else calls them. The first
    /// element's address (not dereferenced when the count is 0) and the count.
    prot inline fn first_(const self) -> unsafe *T {
        return self.base()
    }

    prot inline fn count_(const self) -> usize {
        return self.len
    }

    /// The funnel: the element pointer for arithmetic. Null only when `len`
    /// is 0, and then nothing is read through it.
    priv inline fn base(const self) -> unsafe *T {
        unsafe {
            var word = *(&self.ptr as unsafe *const usize)
            @assume(word != 0 || self.len == 0)
            return word as unsafe *T
        }
    }

    /// `base()` as a pointer to const elements.
    priv inline fn cbase(const self) -> unsafe *const T {
        unsafe {
            return self.base() as unsafe *const T
        }
    }

    pub fn Slice(self) { // empty
        self.ptr = null
        self.len = 0
    }

    pub fn Slice(self, data: unsafe *T, len: usize) { // unchecked: the caller vouches for len
        unsafe {
            *(&self.ptr as unsafe *usize) = data as usize
        }

        self.len = len
    }

    @copy pub fn Slice(self, const other: Self) = default

    @hot_path pub fn op []  (const self, i: usize) -> *const T { // checked
        @unlikely if i >= self.len {
            index_fail(i, self.len)
        }

        unsafe {
            return (self.cbase() + i) as *const T
        }
    }

    @hot_path pub fn op []= (self, i: usize) -> *T { // checked
        @unlikely if i >= self.len {
            index_fail(i, self.len)
        }

        unsafe {
            return (self.base() + i) as *T
        }
    }

    pub fn op []  (const self, r: Range<usize>) -> [const T;] {
        var hi = range_end(r, self.len)
        unsafe {
            return Slice<const T>(self.cbase() + r.begin, hi - r.begin)
        }
    }

    pub fn op []= (self, r: Range<usize>) -> [T;] {
        var hi = range_end(r, self.len)
        unsafe {
            return Slice<T>(self.base() + r.begin, hi - r.begin)
        }
    }

    pub fn op []  (const self, r: RangeFrom<usize>) -> [const T;] {
        var lo = range_from_begin(r, self.len)
        unsafe {
            return Slice<const T>(self.cbase() + lo, self.len - lo)
        }
    }

    pub fn op []= (self, r: RangeFrom<usize>) -> [T;] {
        var lo = range_from_begin(r, self.len)
        unsafe {
            return Slice<T>(self.base() + lo, self.len - lo)
        }
    }

    pub fn op []  (const self, r: RangeTo<usize>) -> [const T;] {
        return Slice<const T>(self.cbase(), range_to_end(r, self.len))
    }

    pub fn op []= (self, r: RangeTo<usize>) -> [T;] {
        return Slice<T>(self.base(), range_to_end(r, self.len))
    }

    // no op in: `for x in s` is the built-in index loop (x a copy, *x the element)

    // Everything that writes is a member of the primary, so the `const`
    // specialization below does not have it.
    pub fn swap(self, i: usize, j: usize) {
        @unlikely if i >= self.len {
            index_fail(i, self.len)
        }

        @unlikely if j >= self.len {
            index_fail(j, self.len)
        }

        if i != j {
            sort_swap_one<T>(self.base() + i, self.base() + j)
        }
    }

    pub fn reverse(self) {
        sort_reverse<T>(self.base(), self.len)
    }

    pub fn rotate(self, n: isize) { // positive rotates left: element n becomes the first
        sort_rotate<T>(self.base(), self.len, n)
    }

    pub fn sort_by(self, cmp: fn(*const T, *const T) -> Ordering) {
        sort_stable_alloc<T, SortFnLess<T>>(self.base(), self.len, SortFnLess<T>(cmp))
    }

    pub fn <K impl Ord> sort_by_key(self, key: fn(*const T) -> K) {
        sort_stable_alloc<T, SortKeyLess<T, K>>(
            self.base(),
            self.len,
            SortKeyLess<T, K>(key),
        )
    }

    pub fn iter_mut(self) -> yield *T {
        var unsafe *p = self.base()
        var i: usize  = 0
        while i < self.len {
            unsafe {
                yield (p + i) as *T
            }

            i += 1
        }
    }

    pub fn get_mut(self, i: usize) -> *T? {
        if i >= self.len {
            return null
        }

        unsafe {
            return (self.base() + i) as *T
        }
    }

    pub fn data_mut(self) -> *T? {
        return self.ptr
    }

    pub fn split_at_mut(self, i: usize) -> ([T;], [T;]) {
        @unlikely if i > self.len {
            range_fail(0, i, self.len)
        }

        unsafe {
            return (Slice<T>(self.base(), i), Slice<T>(self.base() + i, self.len - i))
        }
    }

    pub fn sort(self) requires T impl Ord { // stable; allocates a scratch buffer
        sort_stable<T>(self.base(), self.len)
    }

    pub fn sort_unstable(self) requires T impl Ord {
        sort_unstable<T>(self.base(), self.len)
    }

    pub fn fill(self, const v: T) requires T impl Copyable {
        slice_fill<T>(self.base(), self.len, v)
    }

    pub fn to_owned(const self) -> [T]   requires T impl Copyable {
        var out: [T]
        out.reserve(self.len)
        var unsafe *p = self.cbase()
        var i: usize  = 0
        unsafe {
            while i < self.len {
                out.push(p[i].copy())
                i += 1
            }
        }

        return out
    }
}

/// `[const X;]`: the partial specialization on a const element. It has the
/// read forms only, so `s.sort()` or `s[i] = v` on a `[const X;]` is "no such
/// member" at the call. `T` here is the element WITHOUT its const, which is
/// what `to_owned()` returns a vector of.
pub class <T> Slice<const T> {
    // Invariant: as the primary's.
    priv var ptr: *const T?
    priv var len: usize

    prot inline fn first_(const self) -> unsafe *const T {
        return self.base()
    }

    prot inline fn count_(const self) -> usize {
        return self.len
    }

    priv inline fn base(const self) -> unsafe *const T {
        unsafe {
            var word = *(&self.ptr as unsafe *const usize)
            @assume(word != 0 || self.len == 0)
            return word as unsafe *const T
        }
    }

    priv inline fn cbase(const self) -> unsafe *const T {
        return self.base()
    }

    pub fn Slice(self) {
        self.ptr = null
        self.len = 0
    }

    pub fn Slice(self, data: unsafe *const T, len: usize) {
        unsafe {
            *(&self.ptr as unsafe *usize) = data as usize
        }

        self.len = len
    }

    @copy pub fn Slice(self, const other: Self) = default

    @hot_path pub fn op [] (const self, i: usize) -> *const T { // checked
        @unlikely if i >= self.len {
            index_fail(i, self.len)
        }

        unsafe {
            return (self.base() + i) as *const T
        }
    }

    pub fn op [] (const self, r: Range<usize>) -> [const T;] {
        var hi = range_end(r, self.len)
        unsafe {
            return Slice<const T>(self.base() + r.begin, hi - r.begin)
        }
    }

    pub fn op [] (const self, r: RangeFrom<usize>) -> [const T;] {
        var lo = range_from_begin(r, self.len)
        unsafe {
            return Slice<const T>(self.base() + lo, self.len - lo)
        }
    }

    pub fn op [] (const self, r: RangeTo<usize>) -> [const T;] {
        return Slice<const T>(self.base(), range_to_end(r, self.len))
    }

    pub fn to_owned(const self) -> [T]   requires T impl Copyable {
        var out: [T]
        out.reserve(self.len)
        var unsafe *p = self.cbase()
        var i: usize  = 0
        unsafe {
            while i < self.len {
                out.push(p[i].copy())
                i += 1
            }
        }

        return out
    }
}

// The extends below apply to `Slice<const T>` as well, with `T` the const element.

extend <T> Slice<T> {
    pub fn size(const self) -> usize {
        return self.len
    }

    pub fn is_empty(const self) -> bool {
        return self.len == 0
    }

    pub fn data(const self) -> *const T? {
        return slice_nullable<T>(self.cbase())
    }

    pub fn begin(const self) -> *const T? {
        return slice_nullable<T>(self.cbase())
    }

    pub fn end(const self) -> *const T? {
        unsafe {
            return slice_nullable<T>(self.cbase() + self.len)
        }
    }

    pub fn get(const self, i: usize) -> *const T? {
        return slice_get<T>(self.cbase(), self.len, i)
    }

    pub fn at(const self, i: isize) -> *const T? { // negative counts from the end
        if i >= 0 {
            return slice_get<T>(self.cbase(), self.len, i as usize)
        }

        // -(i + 1) cannot overflow, unlike -i.
        var back = ((0 - (i + 1)) as usize) + 1
        if back > self.len {
            return null
        }

        return slice_get<T>(self.cbase(), self.len, self.len - back)
    }

    pub fn first(const self) -> *const T? {
        return slice_get<T>(self.cbase(), self.len, 0)
    }

    pub fn last(const self) -> *const T? {
        if self.len == 0 {
            return null
        }

        return slice_get<T>(self.cbase(), self.len, self.len - 1)
    }

    pub fn split_at(const self, i: usize) -> ([const T;], [const T;]) {
        @unlikely if i > self.len {
            range_fail(0, i, self.len)
        }

        unsafe {
            var unsafe *p = self.cbase()
            return (Slice<const T>(p, i), Slice<const T>(p + i, self.len - i))
        }
    }

    pub fn iter(const self) -> yield *const T {
        var unsafe *p = self.cbase()
        var i: usize  = 0
        while i < self.len {
            unsafe {
                yield (p + i) as *const T
            }

            i += 1
        }
    }

    pub fn windows(const self, n: usize) -> yield [const T;] {
        @unlikely if n == 0 {
            index_fail(0, 0)
        }

        var unsafe *p = self.cbase()
        var i: usize  = 0
        while i + n <= self.len {
            unsafe {
                yield Slice<const T>(p + i, n)
            }

            i += 1
        }
    }

    pub fn chunks(const self, n: usize) -> yield [const T;] {
        @unlikely if n == 0 {
            index_fail(0, 0)
        }

        var unsafe *p = self.cbase()
        var i: usize  = 0
        while i < self.len {
            var m = self.len - i
            if m > n {
                m = n
            }

            unsafe {
                yield Slice<const T>(p + i, m)
            }

            i += m
        }
    }

    pub fn partition_point(const self, pred: fn(*const T) -> bool) -> usize {
        return sort_partition_point<T>(self.cbase(), self.len, pred)
    }
}

extend <T impl Eq> Slice<T> {
    pub fn op in (const self, const v: T) -> bool {
        return slice_find<T>(self.cbase(), self.len, &v) != self.len
    }

    pub fn contains(const self, const v: T) -> bool {
        return slice_find<T>(self.cbase(), self.len, &v) != self.len
    }

    pub fn index_of(const self, const v: T) -> usize? {
        var at = slice_find<T>(self.cbase(), self.len, &v)
        if at == self.len {
            return null
        }

        return at
    }

    pub fn last_index_of(const self, const v: T) -> usize? {
        var unsafe *p = self.cbase()
        var i         = self.len
        unsafe {
            while i > 0 {
                i -= 1
                if p[i] == v {
                    return i
                }
            }
        }

        return null
    }

    pub fn starts_with(const self, const p: [const T;]) -> bool {
        var n = p.size()
        if n > self.len {
            return false
        }

        return slice_eq<T>(self.cbase(), p.first_(), n)
    }

    pub fn ends_with(const self, const p: [const T;]) -> bool {
        var n = p.size()
        if n > self.len {
            return false
        }

        unsafe {
            return slice_eq<T>(
                self.cbase() + (self.len - n),
                p.first_(),
                n,
            )
        }
    }

    pub fn op == (const self, const o: [const T;]) -> bool {
        if self.len != o.size() {
            return false
        }

        return slice_eq<T>(self.cbase(), o.first_(), self.len)
    }
}

extend <T impl Ord> Slice<T> {
    pub fn is_sorted(const self) -> bool {
        var unsafe *p = self.cbase()
        var i: usize  = 1
        unsafe {
            while i < self.len {
                if (p[i] <=> p[i - 1]) == Ordering::Less {
                    return false
                }

                i += 1
            }
        }

        return true
    }

    pub fn binary_search(const self, const v: T) -> (bool, usize) { // found, and the index or insertion point
        return sort_binary_search<T>(self.cbase(), self.len, &v)
    }
}

// --- element-wise helpers ---------------------------------------------------

/// `p` as a nullable safe pointer.
priv inline fn <T> slice_nullable(p: unsafe *const T) -> *const T? {
    if p == &null {
        return null
    }

    unsafe {
        return p as *const T
    }
}

/// The element at `i`, or null when `i >= n`.
priv inline fn <T> slice_get(p: unsafe *const T, n: usize, i: usize) -> *const T? {
    if i >= n {
        return null
    }

    unsafe {
        return (p + i) as *const T
    }
}

/// True when two elements are equal exactly when their bytes are: integers,
/// `char` and `bool`. Not floats (`-0.0 == 0.0`, NaN) and not types with
/// padding.
priv eval fn <T> slice_bytewise_eq() -> bool {
    return __builtin_is_integral<T>()
}

/// Index of the first element equal to `*v`, or `n`.
priv fn <T impl Eq> slice_find(p: unsafe *const T, n: usize, v: *const T) -> usize {
    unsafe {
        eval if slice_bytewise_eq<T>() {
            // Blocks of a fixed length with no exit inside, so the compare
            // vectorizes; the hit is then located inside its block.
            eval SLICE_FIND_BLOCK: usize = 32
            var x        = *v
            var i: usize = 0
            while i + SLICE_FIND_BLOCK <= n {
                var hit = false
                var k: usize = 0
                while k < SLICE_FIND_BLOCK {
                    hit |= p[i + k] == x
                    k += 1
                }

                if hit {
                    break
                }

                i += SLICE_FIND_BLOCK
            }

            while i < n {
                if p[i] == x {
                    return i
                }

                i += 1
            }

            return n
        } else {
            var i: usize = 0
            while i < n {
                if p[i] == *v {
                    return i
                }

                i += 1
            }

            return n
        }
    }
}

priv fn <T impl Eq> slice_eq(a: unsafe *const T, b: unsafe *const T, n: usize) -> bool {
    if n == 0 || a == b {
        return true
    }

    unsafe {
        eval if slice_bytewise_eq<T>() {
            return __builtin_compare_mem(a as unsafe *const u8, b as unsafe *const u8, n * sizeof T) == 0
        } else {
            var i: usize = 0
            while i < n {
                if !(a[i] == b[i]) {
                    return false
                }

                i += 1
            }

            return true
        }
    }
}

priv fn <T impl Copyable> slice_fill(p: unsafe *T, n: usize, const v: T) {
    unsafe {
        eval if __builtin_is_trivially_copyable<T>() && sizeof T == 1 {
            if n != 0 {
                var b: u8 = 0
                __builtin_copy(&b as unsafe *u8, &v as unsafe *const u8, 1)
                __builtin_set_mem(p as unsafe *u8, b as byte, n)
            }
        } else {
            var i: usize = 0
            while i < n {
                p[i] = v.copy()
                i += 1
            }
        }
    }
}

// --- sorting, reversal, rotation, search ------------------------------------

// Every function below works on a raw range `(base, n)` and is generic over
// the element and, where it compares, over a comparator object, so the `Ord`
// forms inline the comparison and the callback forms make one indirect call
// per comparison.
//
// No function reads or writes outside `[base, base + n)`, the scratch it was
// given, or its own one-element temporary, whatever the comparator returns:
// every loop is bounded by an index, never by a sentinel element.

/// A strict "orders before" test on two elements.
priv interface <T> SortLess {
    fn lt(const self, a: *const T, b: *const T) -> bool
}

// The comparators declare `lt` in their own bodies: the conformance is then
// found in every translation unit that instantiates a sort.
// COMPILER-WORKAROUND(extension-witness): the witness of an `extend ...
// impl SortLess<T>` is not emitted in a user's unit.

/// Compares through the element's own `<=>`; the call inlines.
priv class <T impl Ord> SortOrdLess impl SortLess<T> {
    pub fn SortOrdLess(self) { }

    pub inline fn lt(const self, a: *const T, b: *const T) -> bool {
        return (*a <=> *b) == Ordering::Less
    }
}

/// Compares through a callback.
priv class <T> SortFnLess impl SortLess<T> {
    var f: fn(*const T, *const T) -> Ordering

    pub fn SortFnLess(self, f: fn(*const T, *const T) -> Ordering) {
        self.f = f
    }

    pub inline fn lt(const self, a: *const T, b: *const T) -> bool {
        return self.f(a, b) == Ordering::Less
    }
}

/// Compares the keys a callback extracts. The key function runs twice per
/// comparison; keys are not cached.
priv class <T, K impl Ord> SortKeyLess impl SortLess<T> {
    var key: fn(*const T) -> K

    pub fn SortKeyLess(self, key: fn(*const T) -> K) {
        self.key = key
    }

    pub inline fn lt(const self, a: *const T, b: *const T) -> bool {
        var ka: K = self.key(a)
        var kb: K = self.key(b)
        return (ka <=> kb) == Ordering::Less
    }
}

/// Ranges of this length or shorter are sorted by insertion.
priv eval SORT_INSERTION_MAX: usize = 20

/// From this length the pivot is a recursive pseudo-median: the median of
/// three such medians, each taken over an eighth of the range.
priv eval SORT_PSEUDO_MEDIAN_MIN: usize = 64

/// Elements classified per step by the block partition; an offset fits a
/// byte.
priv eval SORT_BLOCK: usize = 64

/// The run stack of the stable sort holds runs of strictly increasing node
/// power, and a power is at most the bit width of `u64` plus one.
priv eval SORT_RUN_STACK: usize = 72

// --- element movement -------------------------------------------------------

priv inline fn <T> sort_move_into(dst: unsafe *u8, @move src: T) {
    __builtin_construct_at<T>(dst, src)
}

/// Bytes to take from the stack for a one-element temporary. A stack block
/// is aligned for a pointer at least; a stricter element alignment is made
/// up inside a longer block.
priv eval fn <T> sort_tmp_bytes() -> usize {
    return (if alignof T <= sizeof usize => sizeof T else => sizeof T + alignof T)
}

/// The element slot inside a stack block of `sort_tmp_bytes<T>()` bytes.
priv inline fn <T> sort_tmp(raw: unsafe *u8) -> unsafe *T {
    unsafe {
        eval if alignof T <= sizeof usize {
            return raw as unsafe *T
        } else {
            return (raw + ((0usize - (raw as usize)) & (alignof T - 1))) as unsafe *T
        }
    }
}

/// True when an insertion shifts one element at a time: for elements of two
/// words or less that beats locating the slot and calling the block move.
priv eval fn <T> sort_shift_by_element() -> bool {
    return __builtin_is_trivially_relocatable<T>() && (sizeof T <= 2 * sizeof usize)
}

/// True when the partition compares against a bitwise snapshot of the
/// pivot, which the optimizer keeps in a register.
priv eval fn <T> sort_pivot_snapshot() -> bool {
    return __builtin_is_trivially_copyable<T>() && (sizeof T <= sizeof usize)
}

/// Relocates one element: `dst` is uninitialized before and live after, `src`
/// the reverse.
priv inline fn <T> sort_reloc(dst: unsafe *T, src: unsafe *T) {
    unsafe {
        eval if __builtin_is_trivially_relocatable<T>() {
            __builtin_copy(dst as unsafe *u8, src as unsafe *const u8, sizeof T)
        } else {
            sort_move_into<T>(dst as unsafe *u8, *src)
            __builtin_destruct_at(src as *T)
        }
    }
}

/// Relocates `n` elements between ranges that do not overlap.
priv inline fn <T> sort_reloc_n(dst: unsafe *T, src: unsafe *T, n: usize) {
    unsafe {
        eval if __builtin_is_trivially_relocatable<T>() {
            if n != 0 {
                __builtin_copy(dst as unsafe *u8, src as unsafe *const u8, n * sizeof T)
            }
        } else {
            var i: usize = 0
            while i < n {
                sort_reloc<T>(dst + i, src + i)
                i += 1
            }
        }
    }
}

/// Moves `[lo, hi)` up by one element; slot `hi` is uninitialized before and
/// slot `lo` after.
priv inline fn <T> sort_shift_up(base: unsafe *T, lo: usize, hi: usize) {
    unsafe {
        eval if __builtin_is_trivially_relocatable<T>() {
            if hi != lo {
                __builtin_move_mem(
                    (base + lo + 1) as unsafe *u8,
                    (base + lo) as unsafe *const u8,
                    (hi - lo) * sizeof T,
                )
            }
        } else {
            var i = hi
            while i > lo {
                sort_reloc<T>(base + i, base + i - 1)
                i -= 1
            }
        }
    }
}

/// Swaps two distinct elements through the uninitialized slot `tmp`.
priv inline fn <T> sort_swap(a: unsafe *T, b: unsafe *T, tmp: unsafe *T) {
    sort_reloc<T>(tmp, a)
    sort_reloc<T>(a, b)
    sort_reloc<T>(b, tmp)
}

/// Swaps two distinct elements.
priv fn <T> sort_swap_one(a: unsafe *T, b: unsafe *T) {
    unsafe {
        var unsafe *tmp = sort_tmp<T>(__builtin_alloca(sort_tmp_bytes<T>()) as unsafe *u8)
        sort_swap<T>(a, b, tmp)
    }
}

// --- reverse, rotate --------------------------------------------------------

/// Swaps `a[k]` with `b[n - 1 - k]` for every `k < n`: the two halves of a
/// reversal, which do not overlap. The halves arrive as separate parameters
/// of a function that is not inlined, so the backend checks them for overlap
/// once and vectorizes the loop; inside the caller both derive from one
/// pointer and it cannot.
@no_inline
priv fn <T> sort_revswap(a: unsafe *T, b: unsafe *T, n: usize) {
    unsafe {
        var unsafe *tmp = sort_tmp<T>(__builtin_alloca(sort_tmp_bytes<T>()) as unsafe *u8)
        var i: usize    = 0
        while i < n {
            sort_swap<T>(a + i, b + (n - 1 - i), tmp)
            i += 1
        }
    }
}

/// Reverses `[base, base + n)`.
priv fn <T> sort_reverse(base: unsafe *T, n: usize) {
    var half = n / 2
    if half == 0 {
        return
    }

    unsafe {
        sort_revswap<T>(base, base + (n - half), half)
    }
}

priv fn sort_gcd(a0: usize, b0: usize) -> usize {
    var a = a0
    var b = b0
    while b != 0 {
        var t = a % b
        a = b
        b = t
    }

    return a
}

/// Rotates left by `mid`: the element at `mid` becomes the first.
/// `0 < mid < n`.
priv fn <T> sort_rotate_left(base: unsafe *T, n: usize, mid: usize) {
    unsafe {
        eval if sizeof T > 32 {
            // One relocation per element: each cycle of the permutation is
            // walked once through the temporary.
            var unsafe *tmp = sort_tmp<T>(__builtin_alloca(sort_tmp_bytes<T>()) as unsafe *u8)
            var cycles       = sort_gcd(n, mid)
            var start: usize = 0
            while start < cycles {
                sort_reloc<T>(tmp, base + start)
                var i = start
                loop {
                    var j = i + mid
                    if j >= n {
                        j -= n
                    }

                    if j == start {
                        break
                    }

                    sort_reloc<T>(base + i, base + j)
                    i = j
                }

                sort_reloc<T>(base + i, tmp)
                start += 1
            }
        } else {
            sort_reverse<T>(base, mid)
            sort_reverse<T>(base + mid, n - mid)
            sort_reverse<T>(base, n)
        }
    }
}

/// Rotates `[base, base + n)` by `k`. A positive `k` rotates left (toward
/// index 0: the element at index `k` becomes the first), a negative `k`
/// rotates right. `k` is taken modulo `n`.
priv fn <T> sort_rotate(base: unsafe *T, n: usize, k: isize) {
    if n < 2 {
        return
    }

    var mid: usize = 0
    if k >= 0 {
        mid = (k as usize) % n
    } else {
        // -(k + 1) cannot overflow, unlike -k.
        var back = ((0 - (k + 1)) as usize) % n + 1
        mid = n - back
    }

    if mid == 0 {
        return
    }

    sort_rotate_left<T>(base, n, mid)
}

// --- insertion sort ---------------------------------------------------------

/// Sorts `[0, n)` given that `[0, sorted)` is sorted. `1 <= sorted <= n`.
/// Stable.
priv fn <T, C impl SortLess<T>> sort_insertion(base: unsafe *T, sorted: usize, n: usize, const c: C) {
    unsafe {
        var unsafe *tmp = sort_tmp<T>(__builtin_alloca(sort_tmp_bytes<T>()) as unsafe *u8)
        var i           = sorted
        while i < n {
            if c.lt(&base[i], &base[i - 1]) {
                sort_reloc<T>(tmp, base + i)
                eval if sort_shift_by_element<T>() {
                    var j = i
                    loop {
                        sort_reloc<T>(base + j, base + j - 1)
                        j -= 1
                        if j == 0 {
                            break
                        }

                        if !c.lt(&tmp[0], &base[j - 1]) {
                            break
                        }
                    }

                    sort_reloc<T>(base + j, tmp)
                } else {
                    var j = i - 1
                    while j > 0 && c.lt(&tmp[0], &base[j - 1]) {
                        j -= 1
                    }

                    sort_shift_up<T>(base, j, i)
                    sort_reloc<T>(base + j, tmp)
                }
            }

            i += 1
        }
    }
}

// --- unstable sort: introsort -----------------------------------------------

priv inline fn <T, C impl SortLess<T>> sort_sift_down(base:    unsafe *T,
                                                 start:   usize,
                                                 n:       usize,
                                                 const c: C,
                                                 tmp:     unsafe *T) {
    var root = start
    unsafe {
        loop {
            var child = 2 * root + 1
            if child >= n {
                break
            }

            if child + 1 < n && c.lt(&base[child], &base[child + 1]) {
                child += 1
            }

            if !c.lt(&base[root], &base[child]) {
                break
            }

            sort_swap<T>(base + root, base + child, tmp)
            root = child
        }
    }
}

priv fn <T, C impl SortLess<T>> sort_heap(base: unsafe *T, n: usize, const c: C) {
    unsafe {
        var unsafe *tmp = sort_tmp<T>(__builtin_alloca(sort_tmp_bytes<T>()) as unsafe *u8)
        if n < 2 {
            return
        }

        var i = n / 2
        while i > 0 {
            i -= 1
            sort_sift_down<T, C>(base, i, n, c, tmp)
        }

        var end = n
        while end > 1 {
            end -= 1
            sort_swap<T>(base, base + end, tmp)
            sort_sift_down<T, C>(base, 0, end, c, tmp)
        }
    }
}

/// The index of the median of the elements at `a`, `b` and `d`. Compares
/// only; nothing moves.
priv inline fn <T, C impl SortLess<T>> sort_median3(base:    unsafe *T,
                                               a:       usize,
                                               b:       usize,
                                               d:       usize,
                                               const c: C) -> usize {
    unsafe {
        var x = c.lt(&base[a], &base[b])
        var y = c.lt(&base[a], &base[d])
        if x == y {
            // `a` is the least or the greatest of the three.
            var z = c.lt(&base[b], &base[d])
            return (if z != x => d else => b)
        }
    }

    return a
}

/// The pseudo-median of about `n^0.63` elements: the median of three, each
/// of which is the same choice over the eighth of the range that starts at
/// `a`, `b` or `d`, down to eighths shorter than eight elements. `n` is the
/// length of each eighth. A pivot this close to the median saves more
/// comparisons in the partitions below it than its choice costs.
priv fn <T, C impl SortLess<T>> sort_median3_rec(base:    unsafe *T,
                                            a:       usize,
                                            b:       usize,
                                            d:       usize,
                                            n:       usize,
                                            const c: C) -> usize {
    var ia = a
    var ib = b
    var id = d
    if n * 8 >= SORT_PSEUDO_MEDIAN_MIN {
        var n8 = n / 8
        ia = sort_median3_rec<T, C>(base, a, a + 4 * n8, a + 7 * n8, n8, c)
        ib = sort_median3_rec<T, C>(base, b, b + 4 * n8, b + 7 * n8, n8, c)
        id = sort_median3_rec<T, C>(base, d, d + 4 * n8, d + 7 * n8, n8, c)
    }

    return sort_median3<T, C>(base, ia, ib, id, c)
}

/// True when the range is sorted on return: it was non-descending already,
/// or it was non-ascending and is reversed here.
priv fn <T, C impl SortLess<T>> sort_presorted(base: unsafe *T, n: usize, const c: C) -> bool {
    var i: usize = 1
    unsafe {
        while i < n && !c.lt(&base[i], &base[i - 1]) {
            i += 1
        }

        if i == n {
            return true
        }

        if i != 1 {
            return false
        }

        while i < n && !c.lt(&base[i - 1], &base[i]) {
            i += 1
        }

        if i != n {
            return false
        }
    }

    sort_reverse<T>(base, n)
    return true
}

/// Hoare partition of `[0, n)`, `n >= 3`. Returns the pivot's final index
/// `p`: nothing in `[0, p)` orders after the pivot and nothing in
/// `(p, n)` orders before it. Both sides exclude `p`, so each is shorter
/// than `n` whatever the comparator answers.
priv fn <T, C impl SortLess<T>> sort_partition(base: unsafe *T, n: usize, const c: C) -> usize {
    unsafe {
        var unsafe *tmp = sort_tmp<T>(__builtin_alloca(sort_tmp_bytes<T>()) as unsafe *u8)
        var unsafe *pv  = sort_tmp<T>(__builtin_alloca(sort_tmp_bytes<T>()) as unsafe *u8)
        var n8 = n / 8
        var at = (if n >= SORT_PSEUDO_MEDIAN_MIN
                  => sort_median3_rec<T, C>(base, 0, 4 * n8, 7 * n8, n8, c)
                  else => sort_median3<T, C>(base, 0, 4 * n8, 7 * n8, c))

        // The pivot sits at index 0, which the scans below never reach.
        if at != 0 {
            sort_swap<T>(base, base + at, tmp)
        }

        eval if sort_pivot_snapshot<T>() {
            __builtin_copy(pv as unsafe *u8, base as unsafe *const u8, sizeof T)
        } else {
            pv = base
        }

        var i: usize = 1
        var j        = n - 1
        eval if sort_pivot_snapshot<T>() {
            // Hoare partition by blocks: classify SORT_BLOCK elements at
            // each end without branching on the data, recording the offsets
            // of the ones on the wrong side, then swap those pairwise. The
            // two blocks never overlap while more than 2 * SORT_BLOCK
            // elements separate i and j, and an offset is below SORT_BLOCK,
            // so every access stays inside [i, j].
            var left_off:  [u8; SORT_BLOCK]
            var right_off: [u8; SORT_BLOCK]
            var left_n:    usize            = 0
            var right_n:   usize            = 0
            var left_at:   usize            = 0
            var right_at:  usize            = 0
            while j - i + 1 > 2 * SORT_BLOCK {
                if left_n == 0 {
                    left_at = 0
                    var k: usize = 0
                    while k < SORT_BLOCK {
                        left_off[left_n] = k as u8
                        left_n += (!c.lt(&base[i + k], &pv[0])) as usize
                        k += 1
                    }
                }

                if right_n == 0 {
                    right_at = 0
                    var k: usize = 0
                    while k < SORT_BLOCK {
                        right_off[right_n] = k as u8
                        right_n += (!c.lt(&pv[0], &base[j - k])) as usize
                        k += 1
                    }
                }

                var pairs       = (if left_n < right_n => left_n else => right_n)
                var k:    usize = 0
                while k < pairs {
                    sort_swap<T>(
                        base + i + left_off[left_at + k] as usize,
                        base + j - right_off[right_at + k] as usize,
                        tmp,
                    )

                    k += 1
                }

                left_n -= pairs
                right_n -= pairs
                left_at += pairs
                right_at += pairs
                if left_n == 0 {
                    i += SORT_BLOCK
                }

                if right_n == 0 {
                    j -= SORT_BLOCK
                }
            }

            // A block left half done is still inside [i, j]; the scan below
            // takes the range as it stands.
        }

        loop {
            while i <= j && c.lt(&base[i], &pv[0]) {
                i += 1
            }

            while i <= j && c.lt(&pv[0], &base[j]) {
                j -= 1
            }

            if i >= j {
                break
            }

            sort_swap<T>(base + i, base + j, tmp)
            i += 1
            j -= 1
        }

        // j is i or i - 1, and [1, j] holds nothing that orders after the pivot.
        if j != 0 {
            sort_swap<T>(base, base + j, tmp)
        }

        return j
    }
}

priv fn <T, C impl SortLess<T>> sort_intro(base: unsafe *T, n0: usize, limit0: u32, const c: C) {
    var unsafe *b    = base
    var        n     = n0
    var        limit = limit0
    unsafe {
        loop {
            if n <= SORT_INSERTION_MAX {
                if n > 1 {
                    sort_insertion<T, C>(b, 1, n, c)
                }

                return
            }

            if limit == 0 {
                sort_heap<T, C>(b, n, c)
                return
            }

            limit -= 1
            if sort_presorted<T, C>(b, n, c) {
                return
            }

            var p     = sort_partition<T, C>(b, n, c)
            var right = n - p - 1
            // Recursing into the shorter side bounds the stack by log2(n).
            if p < right {
                sort_intro<T, C>(b, p, limit, c)
                b = b + p + 1
                n = right
            } else {
                sort_intro<T, C>(b + p + 1, right, limit, c)
                n = p
            }
        }
    }
}

/// floor(log2(n)) for `n >= 1`.
priv inline fn sort_log2(n: usize) -> u32 {
    return (sizeof usize * 8 - 1) as u32 - __builtin_clz(n)
}

/// Unstable sort (introsort).
priv fn <T, C impl SortLess<T>> sort_unstable_with(base: unsafe *T, n: usize, const c: C) {
    if n < 2 {
        return
    }

    sort_intro<T, C>(base, n, 2 * sort_log2(n), c)
}

// --- stable sort: natural merge sort ----------------------------------------

/// Length of the run starting at `b`, at least 2 when `m >= 2`. A strictly
/// descending run is reversed in place, which keeps equal elements in order.
priv fn <T, C impl SortLess<T>> sort_next_run(b: unsafe *T, m: usize, const c: C) -> usize {
    if m < 2 {
        return m
    }

    var i: usize = 2
    unsafe {
        if c.lt(&b[1], &b[0]) {
            while i < m && c.lt(&b[i], &b[i - 1]) {
                i += 1
            }

            sort_reverse<T>(b, i)
        } else {
            while i < m && !c.lt(&b[i], &b[i - 1]) {
                i += 1
            }
        }
    }

    return i
}

/// The number of elements in `[lo, hi)`.
priv inline fn <T> sort_count(lo: unsafe *const T, hi: unsafe *const T) -> usize {
    return ((hi as usize) - (lo as usize)) / sizeof T
}

/// Merges the sorted runs `[s, s + n1)` and `[s + n1, s + n1 + n2)`. The
/// shorter run moves to `scratch`, which holds at least `min(n1, n2)`
/// elements.
///
/// The cursors are pointers, so a step is the comparison, one relocation
/// and the cursor updates. For elements of two words or less a step selects
/// the source and advances both cursors by the comparison's value, with no
/// branch on the data. Larger elements branch: x86 backends turn the select
/// of a large element's source into a branch unless it is marked
/// unpredictable, and the marked form takes about a quarter more
/// instructions per element than the branch, though it mispredicts less.
priv fn <T, C impl SortLess<T>> sort_merge(base:    unsafe *T,
                                      s:       usize,
                                      n1:      usize,
                                      n2:      usize,
                                      const c: C,
                                      scratch: unsafe *T) {
    unsafe {
        var a = base + s
        var b = a + n1
        if !c.lt(&b[0], &a[n1 - 1]) {
            return
        }

        if n1 <= n2 {
            // Forward: the left run is in scratch, the right run in place;
            // `d` is the next free slot, and the slots before it hold
            // what `l` and `r` have passed.
            sort_reloc_n<T>(scratch, a, n1)
            var l    = scratch
            var lend = scratch + n1
            var r    = b
            var rend = b + n2
            var d    = a
            eval if sort_shift_by_element<T>() {
                while l != lend && r != rend {
                    var right = c.lt(&r[0], &l[0])
                    sort_reloc<T>(d, (if right => r else => l))
                    r += right as usize
                    l += (!right) as usize
                    d += 1
                }
            } else {
                while l != lend && r != rend {
                    if c.lt(&r[0], &l[0]) {
                        sort_reloc<T>(d, r)
                        r += 1
                    } else {
                        sort_reloc<T>(d, l)
                        l += 1
                    }

                    d += 1
                }
            }

            // What is left of the right run is in place already.
            sort_reloc_n<T>(d, l, sort_count<T>(l, lend))
        } else {
            // Backward: the right run is in scratch, the left run in place;
            // `l`, `r` and `d` are one past the next element of each. An
            // equal pair places the right run's element last.
            sort_reloc_n<T>(scratch, b, n2)
            var l = b
            var r = scratch + n2
            var d = b + n2
            eval if sort_shift_by_element<T>() {
                while l != a && r != scratch {
                    var lp   = l - 1
                    var rp   = r - 1
                    var left = c.lt(&rp[0], &lp[0])
                    d -= 1
                    sort_reloc<T>(d, (if left => lp else => rp))
                    l -= left as usize
                    r -= (!left) as usize
                }
            } else {
                while l != a && r != scratch {
                    var lp = l - 1
                    var rp = r - 1
                    d -= 1
                    if c.lt(&rp[0], &lp[0]) {
                        sort_reloc<T>(d, lp)
                        l = lp
                    } else {
                        sort_reloc<T>(d, rp)
                        r = rp
                    }
                }
            }

            // What is left of the left run is in place already; `d == l +
            // (r - scratch)`.
            sort_reloc_n<T>(l, scratch, sort_count<T>(scratch, r))
        }
    }
}

/// The depth, in the nearly-optimal merge tree over `[0, n)`, of the node
/// between the adjacent runs `[s1, s1 + n1)` and `[s1 + n1, s1 + n1 + n2)`.
priv fn sort_node_power(s1: usize, n1: usize, n2: usize, n: usize) -> u32 {
    var a          = 2 * (s1 as u64) + (n1 as u64)
    var b          = a + (n1 as u64) + (n2 as u64)
    var total      = n as u64
    var power: u32 = 0
    loop {
        power += 1
        if a >= total {
            a -= total
            b -= total
        } else if b >= total {
            break
        }

        a <<= 1
        b <<= 1
    }

    return power
}

/// Stable sort of `[0, n)`; `first` is the length of the run at index 0, as
/// `sort_next_run` returns it. `scratch` holds `n / 2` elements.
priv fn <T, C impl SortLess<T>> sort_merge_runs(base:    unsafe *T,
                                           n:       usize,
                                           first:   usize,
                                           const c: C,
                                           scratch: unsafe *T) {
    var run_start: [usize; SORT_RUN_STACK]
    var run_len:   [usize; SORT_RUN_STACK]
    var run_power: [u32; SORT_RUN_STACK]
    var top:       usize                   = 0
    var s:         usize                   = 0
    var len                                = first
    unsafe {
        loop {
            if len < SORT_INSERTION_MAX {
                var want = n - s
                if want > SORT_INSERTION_MAX {
                    want = SORT_INSERTION_MAX
                }

                sort_insertion<T, C>(base + s, len, want, c)
                len = want
            }

            if top > 0 {
                var power = sort_node_power(run_start[top - 1], run_len[top - 1], len, n)
                while top > 1 && run_power[top - 2] > power {
                    sort_merge<T, C>(
                        base,
                        run_start[top - 2],
                        run_len[top - 2],
                        run_len[top - 1],
                        c,
                        scratch,
                    )

                    run_len[top - 2] += run_len[top - 1]
                    top -= 1
                }

                run_power[top - 1] = power
            }

            run_start[top] = s
            run_len[top]   = len
            run_power[top] = 0
            top += 1
            s += len
            if s >= n {
                break
            }

            len = sort_next_run<T, C>(base + s, n - s, c)
        }

        while top > 1 {
            sort_merge<T, C>(
                base,
                run_start[top - 2],
                run_len[top - 2],
                run_len[top - 1],
                c,
                scratch,
            )

            run_len[top - 2] += run_len[top - 1]
            top -= 1
        }
    }
}

/// Stable sort; allocates the `n / 2` scratch once, and only when the range
/// is not one run already.
priv fn <T, C impl SortLess<T>> sort_stable_alloc(base: unsafe *T, n: usize, const c: C) {
    if n < 2 {
        return
    }

    if n <= SORT_INSERTION_MAX {
        sort_insertion<T, C>(base, 1, n, c)
        return
    }

    var first = sort_next_run<T, C>(base, n, c)
    if first == n {
        return
    }

    // n / 2 elements of a range that exists cannot overflow.
    var bytes       = n / 2 * sizeof T
    var unsafe *raw = alloc_raw(bytes, alignof T)
    @unlikely if raw == &null {
        oom(bytes, alignof T)
    }

    unsafe {
        sort_merge_runs<T, C>(base, n, first, c, raw as unsafe *T)
    }

    free_raw(raw, bytes, alignof T)
}

// --- entry points -----------------------------------------------------------

priv fn <T impl Ord> sort_unstable(base: unsafe *T, n: usize) {
    eval if sort_radix_applies<T>() {
        if n >= SORT_FLAG_MIN {
            if !sort_presorted<T, SortOrdLess<T>>(base, n, SortOrdLess<T>()) {
                sort_flag<T>(base, n, sizeof T - 1, 2 * sort_log2(n))
            }

            return
        }
    }

    sort_unstable_with<T, SortOrdLess<T>>(base, n, SortOrdLess<T>())
}

// --- unstable sort of integers: in-place MSD radix sort ---------------------

/// Ranges at least this long sort by in-place radix when the element is a
/// primitive integer; shorter ones, and the buckets that come out shorter,
/// go to the introsort.
priv eval SORT_FLAG_MIN: usize = 128

/// Buckets this short sort by the branch-free insertion below.
priv eval SORT_SMALL_INT_MAX: usize = 32

/// Stores the integer whose radix key is `key` at `p`.
priv inline fn <T> sort_radix_store(p: unsafe *T, key: u64) {
    var k = key
    eval if __builtin_is_signed<T>() {
        k ^= 1u64 << (sizeof T * 8 - 1)
    }

    unsafe {
        eval if sizeof T == 1 {
            var w = k as u8
            __builtin_copy(p as unsafe *u8, &w as unsafe *const u8, 1)
        } else if sizeof T == 2 {
            var w = k as u16
            __builtin_copy(p as unsafe *u8, &w as unsafe *const u8, 2)
        } else if sizeof T == 4 {
            var w = k as u32
            __builtin_copy(p as unsafe *u8, &w as unsafe *const u8, 4)
        } else {
            __builtin_copy(p as unsafe *u8, &k as unsafe *const u8, 8)
        }
    }
}

/// Sorts at most SORT_SMALL_INT_MAX primitive integers with no branch on
/// the data: their radix keys are sorted on the stack by an insertion that
/// walks the whole sorted prefix for each key, carrying the smaller of each
/// pair down, and the values are stored back from the keys. Quadratic.
priv fn <T> sort_small_int(base: unsafe *T, n: usize) {
    var keys: [u64; SORT_SMALL_INT_MAX]
    unsafe {
        var i: usize = 0
        while i < n {
            keys[i] = sort_radix_key<T>(base + i)
            i += 1
        }

        i = 1
        while i < n {
            var x = keys[i]
            var j = i
            while j > 0 {
                var y  = keys[j - 1]
                var gt = y > x
                keys[j] = (if gt => y else => x)
                x = (if gt => x else => y)
                j -= 1
            }

            keys[0] = x
            i += 1
        }

        i = 0
        while i < n {
            sort_radix_store<T>(base + i, keys[i])
            i += 1
        }
    }
}

/// American flag sort of `[base, base + n)` on byte `digit` of the radix keys
/// and the bytes below it: one pass counts the digits, a second moves every
/// element into its bucket by swapping along cycles, then each bucket is
/// sorted on the next byte. Needs no memory beyond the counts on the stack;
/// recursion is at most one level per byte. Unstable.
priv fn <T> sort_flag(base: unsafe *T, n: usize, digit: usize, limit: u32) requires T impl Ord {
    var head: [usize; 256]
    var tail: [usize; 256]
    unsafe {
        var unsafe *tmp = sort_tmp<T>(__builtin_alloca(sort_tmp_bytes<T>()) as unsafe *u8)
        var shift       = digit * 8
        var v: usize    = 0
        while v < 256 {
            tail[v] = 0
            v += 1
        }

        var i: usize = 0
        while i < n {
            tail[((sort_radix_key<T>(base + i) >> shift) & 255) as usize] += 1
            i += 1
        }

        var at: usize = 0
        v = 0
        while v < 256 {
            head[v] = at
            at += tail[v]
            tail[v] = at
            v += 1
        }

        // Bucket v holds [head[v], tail[v]) once its elements are in place;
        // head[v] walks up as they arrive. The element in hand is placed at
        // the head of its digit's bucket, and what was there is taken next.
        v = 0
        while v < 256 {
            while head[v] < tail[v] {
                var d = ((sort_radix_key<T>(base + head[v]) >> shift) & 255) as usize
                while d != v {
                    sort_swap<T>(base + head[v], base + head[d], tmp)
                    head[d] += 1
                    d = ((sort_radix_key<T>(base + head[v]) >> shift) & 255) as usize
                }

                head[v] += 1
            }

            v += 1
        }

        var start: usize = 0
        v = 0
        while v < 256 {
            // On the last byte every key in a bucket is equal.
            var m = tail[v] - start
            if m > 1 && digit != 0 {
                if m <= SORT_SMALL_INT_MAX {
                    sort_small_int<T>(base + start, m)
                } else if m < SORT_FLAG_MIN {
                    sort_intro<T, SortOrdLess<T>>(base + start, m, limit, SortOrdLess<T>())
                } else {
                    sort_flag<T>(base + start, m, digit - 1, limit)
                }
            }

            start = tail[v]
            v += 1
        }
    }
}

priv fn <T impl Ord> sort_stable(base: unsafe *T, n: usize) {
    eval if sort_radix_applies<T>() {
        if n >= SORT_RADIX_MIN {
            var first = sort_next_run<T, SortOrdLess<T>>(base, n, SortOrdLess<T>())
            if first != n {
                sort_radix_alloc<T>(base, n)
            }

            return
        }
    }

    sort_stable_alloc<T, SortOrdLess<T>>(base, n, SortOrdLess<T>())
}

// --- stable sort of integers: LSD radix sort --------------------------------

/// Ranges at least this long sort by radix when the element is a primitive
/// integer; shorter ones merge.
priv eval SORT_RADIX_MIN: usize = 256

/// True for the primitive integers of up to 64 bits (and `bool` and
/// `char`): their `Ord` is the built-in order of their bits, read as
/// unsigned once a signed type's sign bit is flipped.
priv eval fn <T> sort_radix_applies() -> bool {
    return __builtin_is_integral<T>() && sizeof T <= sizeof u64
}

/// The radix key of the element at `p`: its bits as an unsigned value of
/// the same width, copied into that type so neither the byte order nor the
/// aliasing rules matter, with the sign bit flipped for a signed type.
priv inline fn <T> sort_radix_key(p: unsafe *const T) -> u64 {
    var k: u64 = 0
    unsafe {
        eval if sizeof T == 1 {
            var w: u8 = 0
            __builtin_copy(&w as unsafe *u8, p as unsafe *const u8, 1)
            k = w
        } else if sizeof T == 2 {
            var w: u16 = 0
            __builtin_copy(&w as unsafe *u8, p as unsafe *const u8, 2)
            k = w
        } else if sizeof T == 4 {
            var w: u32 = 0
            __builtin_copy(&w as unsafe *u8, p as unsafe *const u8, 4)
            k = w
        } else {
            __builtin_copy(&k as unsafe *u8, p as unsafe *const u8, 8)
        }
    }

    eval if __builtin_is_signed<T>() {
        k ^= 1u64 << (sizeof T * 8 - 1)
    }

    return k
}

/// Sorts `[base, base + n)` by its radix keys, a byte per pass, least
/// significant first. `scratch` holds `n` elements. One pass over the input
/// counts every digit; a digit that is equal in every key costs no pass.
/// Stable, so equal keys keep their order; for integers that is also the
/// order of equal values.
priv fn <T> sort_radix(base: unsafe *T, n: usize, scratch: unsafe *T) {
    var counts: [usize; 2048]
    unsafe {
        var d: usize = 0
        while d < 256 * sizeof T {
            counts[d] = 0
            d += 1
        }

        var i: usize = 0
        while i < n {
            var k        = sort_radix_key<T>(base + i)
            var b: usize = 0
            while b < sizeof T {
                counts[b * 256 + ((k >> (b * 8)) & 255) as usize] += 1
                b += 1
            }

            i += 1
        }

        var unsafe *src = base
        var unsafe *dst = scratch
        var b: usize    = 0
        while b < sizeof T {
            var unsafe *c = &counts[b * 256] as unsafe *usize
            var shift     = b * 8
            var first     = ((sort_radix_key<T>(src) >> shift) & 255) as usize
            if c[first] != n {
                // Counts become the first slot of each digit.
                var at: usize = 0
                var v:  usize = 0
                while v < 256 {
                    var m = c[v]
                    c[v] = at
                    at += m
                    v += 1
                }

                var j: usize = 0
                while j < n {
                    var digit = ((sort_radix_key<T>(src + j) >> shift) & 255) as usize
                    __builtin_copy((dst + c[digit]) as unsafe *u8, (src + j) as unsafe *const u8, sizeof T)
                    c[digit] += 1
                    j += 1
                }

                var unsafe *t = src
                src = dst
                dst = t
            }

            b += 1
        }

        if src != base {
            __builtin_copy(base as unsafe *u8, src as unsafe *const u8, n * sizeof T)
        }
    }
}

priv fn <T> sort_radix_alloc(base: unsafe *T, n: usize) {
    // n elements of a range that exists cannot overflow.
    var bytes       = n * sizeof T
    var unsafe *raw = alloc_raw(bytes, alignof T)
    @unlikely if raw == &null {
        oom(bytes, alignof T)
    }

    unsafe {
        sort_radix<T>(base, n, raw as unsafe *T)
    }

    free_raw(raw, bytes, alignof T)
}

// --- search -----------------------------------------------------------------

/// Index of the first element that does not order before `*v` in a sorted
/// range. The loop halves the length and keeps the base, with no early
/// exit, so the number of steps depends on `n` alone.
priv fn <T, C impl SortLess<T>> sort_lower_bound(base:    unsafe *const T,
                                            n:       usize,
                                            v:       *const T,
                                            const c: C) -> usize {
    if n == 0 {
        return 0
    }

    var lo: usize = 0
    var len       = n
    unsafe {
        while len > 1 {
            var half = len / 2
            // The comparison is unpredictable by construction, and only the
            // hint keeps this step a conditional move: x86 backends turn the
            // select into a branch inside an innermost loop.
            @unpredictable if c.lt(&base[lo + half - 1], v) {
                lo += half
            }

            len -= half
        }

        if c.lt(&base[lo], v) {
            lo += 1
        }
    }

    return lo
}

/// `(true, index of the first element equal to v)`, or `(false, insertion
/// point)`. The range is sorted.
priv fn <T, C impl SortLess<T>> sort_binary_search_with(base:    unsafe *const T,
                                                        n:       usize,
                                                        v:       *const T,
                                                        const c: C) -> (bool, usize) {
    var at    = sort_lower_bound<T, C>(base, n, v, c)
    var found = false
    unsafe {
        if at < n {
            found = !c.lt(v, &base[at])
        }
    }

    return (found, at)
}

priv fn <T impl Ord> sort_binary_search(base: unsafe *const T, n: usize, v: *const T) -> (bool, usize) {
    return sort_binary_search_with<T, SortOrdLess<T>>(base, n, v, SortOrdLess<T>())
}

/// Index of the first element for which `pred` is false, in a range where
/// every element satisfying `pred` precedes every element that does not.
priv fn <T> sort_partition_point(base: unsafe *const T, n: usize, pred: fn(*const T) -> bool) -> usize {
    if n == 0 {
        return 0
    }

    var lo: usize = 0
    var len       = n
    unsafe {
        while len > 1 {
            var half = len / 2
            // Hinted as in sort_lower_bound.
            @unpredictable if pred(&base[lo + half - 1]) {
                lo += half
            }

            len -= half
        }

        if pred(&base[lo]) {
            lo += 1
        }
    }

    return lo
}
