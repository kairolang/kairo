/// builtin/containers/slice.k

import base::cmp::*
import base::copy::*
import base::intrinsics::*
import base::range::*
import builtin::Null
import containers::vector::*

/// Callbacks are `fn` values: one indirect call per element, no inlining.
/// Fine for most code; a callable-interface bound will replace them later.

/// One copy for every element type.
@cold_path @no_inline
prot fn index_fail(i: usize, len: usize) -> ! {
    // BODY-MIN
    __builtin_trap()
}

@cold_path @no_inline
prot fn range_fail(lo: usize, hi: usize, len: usize) -> ! {
    // BODY-MIN
    __builtin_trap()
}

/// A view: copied freely, owns nothing. Two words. Reads through op [],
/// writes through op []=.
pub class <T> Slice {
    priv var ptr: *T?   // null only when len == 0
    priv var len: usize

    /// What a `for x in s` loop reads; nothing else calls them. The first
    /// element's address (not dereferenced when the count is 0) and the count.
    prot inline fn first_(const self) -> unsafe *T {
        unsafe {
            return (*(&self.ptr as unsafe *const usize)) as unsafe *T
        }
    }

    prot inline fn count_(const self) -> usize {
        return self.len
    }

    pub fn Slice(self) { // empty
        // BODY-MIN
        self.ptr = null
        self.len = 0
    }

    pub fn Slice(self, data: unsafe *T, len: usize) { // unchecked: the caller vouches for len
        // BODY-MIN
        unsafe {
            *(&self.ptr as unsafe *usize) = data as usize
        }

        self.len = len
    }

    @copy pub fn Slice(self, const other: Self) = default

    @hot_path pub fn op []  (const self, i: usize) -> *const T { // checked
        // BODY-MIN
        if i >= self.len {
            index_fail(i, self.len)
        }

        unsafe {
            return ((*(&self.ptr as unsafe *const usize)) as unsafe *const T + i) as *const T
        }
    }

    @hot_path pub fn op []= (self, i: usize) -> *T { // checked
        // BODY-MIN
        if i >= self.len {
            index_fail(i, self.len)
        }

        unsafe {
            return ((*(&self.ptr as unsafe *const usize)) as unsafe *T + i) as *T
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

    // no op in: `for x in s` is the built-in index loop (x a copy, *x the element)

    // Everything that writes is a member of the primary, so the `const`
    // specialization below does not have it.
    pub fn swap(self, i: usize, j: usize) {
        __builtin_trap() // BODY-TODO
    }

    pub fn reverse(self) {
        __builtin_trap() // BODY-TODO
    }

    pub fn rotate(self, n: isize) {
        __builtin_trap() // BODY-TODO
    }

    pub fn sort_by(self, cmp: fn(*const T, *const T) -> Ordering) {
        __builtin_trap() // BODY-TODO
    }

    pub fn <K impl Ord> sort_by_key(self, key: fn(*const T) -> K) {
        __builtin_trap() // BODY-TODO
    }

    pub fn iter_mut(self) -> yield *T {
        __builtin_trap() // BODY-TODO
    }

    pub fn get_mut(self, i: usize) -> *T? {
        __builtin_trap() // BODY-TODO
    }

    pub fn data_mut(self) -> *T? {
        // BODY-MIN
        return self.ptr
    }

    pub fn split_at_mut(self, i: usize) -> ([T;], [T;]) {
        __builtin_trap() // BODY-TODO
    }

    pub fn sort(self) requires T impl Ord { // stable; allocates a scratch buffer
        __builtin_trap() // BODY-TODO
    }

    pub fn sort_unstable(self) requires T impl Ord {
        __builtin_trap() // BODY-TODO
    }

    pub fn fill(self, const v: T) requires T impl Copyable {
        __builtin_trap() // BODY-TODO
    }

    pub fn to_owned(const self) -> [T]   requires T impl Copyable {
        __builtin_trap() // BODY-TODO
    }
}

/// `[const X;]`: the partial specialization on a const element. It has the
/// read forms only, so `s.sort()` or `s[i] = v` on a `[const X;]` is "no such
/// member" at the call. `T` here is the element WITHOUT its const, which is
/// what `to_owned()` returns a vector of.
pub class <T> Slice<const T> {
    priv var ptr: *const T?
    priv var len: usize

    prot inline fn first_(const self) -> unsafe *const T {
        unsafe {
            return (*(&self.ptr as unsafe *const usize)) as unsafe *const T
        }
    }

    prot inline fn count_(const self) -> usize {
        return self.len
    }

    pub fn Slice(self) {
        // BODY-MIN
        self.ptr = null
        self.len = 0
    }

    pub fn Slice(self, data: unsafe *const T, len: usize) {
        // BODY-MIN
        unsafe {
            *(&self.ptr as unsafe *usize) = data as usize
        }

        self.len = len
    }

    @copy pub fn Slice(self, const other: Self) = default

    @hot_path pub fn op [] (const self, i: usize) -> *const T { // checked
        // BODY-MIN
        if i >= self.len {
            index_fail(i, self.len)
        }

        unsafe {
            return ((*(&self.ptr as unsafe *const usize)) as unsafe *const T + i) as *const T
        }
    }

    pub fn op [] (const self, r: Range<usize>) -> [const T;] {
        __builtin_trap() // BODY-TODO
    }

    pub fn op [] (const self, r: RangeFrom<usize>) -> [const T;] {
        __builtin_trap() // BODY-TODO
    }

    pub fn op [] (const self, r: RangeTo<usize>) -> [const T;] {
        __builtin_trap() // BODY-TODO
    }

    pub fn to_owned(const self) -> [T]   requires T impl Copyable {
        __builtin_trap() // BODY-TODO
    }
}

// The extends below apply to `Slice<const T>` as well, with `T` the const element.

extend <T> Slice<T> {
    pub fn size(const self) -> usize {
        // BODY-MIN
        return self.len
    }

    pub fn is_empty(const self) -> bool {
        // BODY-MIN
        return self.len == 0
    }

    pub fn data(const self) -> *const T? {
        // BODY-MIN
        return self.ptr
    }

    pub fn begin(const self) -> *const T? {
        __builtin_trap() // BODY-TODO
    }

    pub fn end(const self) -> *const T? {
        __builtin_trap() // BODY-TODO
    }

    pub fn get(const self, i: usize) -> *const T? {
        __builtin_trap() // BODY-TODO
    }

    pub fn at(const self, i: isize) -> *const T? { // negative counts from the end
        __builtin_trap() // BODY-TODO
    }

    pub fn first(const self) -> *const T? {
        __builtin_trap() // BODY-TODO
    }

    pub fn last(const self) -> *const T? {
        __builtin_trap() // BODY-TODO
    }

    pub fn split_at(const self, i: usize) -> ([const T;], [const T;]) {
        __builtin_trap() // BODY-TODO
    }

    pub fn iter(const self) -> yield *const T {
        __builtin_trap() // BODY-TODO
    }

    pub fn windows(const self, n: usize) -> yield [const T;] {
        __builtin_trap() // BODY-TODO
    }

    pub fn chunks(const self, n: usize) -> yield [const T;] {
        __builtin_trap() // BODY-TODO
    }

    pub fn partition_point(const self, pred: fn(*const T) -> bool) -> usize {
        __builtin_trap() // BODY-TODO
    }
}

extend <T impl Eq> Slice<T> {
    pub fn op in (const self, const v: T) -> bool {
        __builtin_trap() // BODY-TODO
    }

    pub fn contains(const self, const v: T) -> bool {
        __builtin_trap() // BODY-TODO
    }

    pub fn index_of(const self, const v: T) -> usize? {
        __builtin_trap() // BODY-TODO
    }

    pub fn last_index_of(const self, const v: T) -> usize? {
        __builtin_trap() // BODY-TODO
    }

    pub fn starts_with(const self, const p: [const T;]) -> bool {
        __builtin_trap() // BODY-TODO
    }

    pub fn ends_with(const self, const p: [const T;]) -> bool {
        __builtin_trap() // BODY-TODO
    }

    pub fn op == (const self, const o: [const T;]) -> bool {
        __builtin_trap() // BODY-TODO
    }
}

extend <T impl Ord> Slice<T> {
    pub fn is_sorted(const self) -> bool {
        __builtin_trap() // BODY-TODO
    }

    pub fn binary_search(const self, const v: T) -> (bool, usize) { // found, and the index or insertion point
        __builtin_trap() // BODY-TODO
    }
}
