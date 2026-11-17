/// builtin/containers/hash_set.k

import base::cmp::*
import base::copy::*
import base::hash::*
import base::intrinsics::*
import base::iter::*
import builtin::Null
import containers::raw_table::*
import containers::slice::*

priv inline fn <T impl Copyable> set_copy_of(const x: T) -> T {
    return x.copy()
}

/// Insertion-ordered. Two words. MOVE-ONLY: `copy()` duplicates.
///
/// A set literal is built as `HashSet()`, `reserve(n)`, then `insert(x)` per
/// element in written order; a repeated element keeps its first place.
///
/// Any insert may move every element (growth), and any removal moves at
/// least one: a pointer from `get`, `first`, `last` or an iteration is good
/// until the next insert or removal.
///
/// The set operations walk `self` in its order unless they say otherwise;
/// none of them allocates except `|=` and `^=`, which reserve once.
@relocatable
pub class <T impl Hash> HashSet {
    priv var t: RawTable

    pub fn HashSet(self) { }

    @move pub fn HashSet(self, other: Self) {
        self.t.steal(&other.t)
    }

    pub fn op finally(self) {
        rt_release<T>(&self.t)
    }

    pub fn op in (const self) -> yield *const T {
        var i: usize = 0
        while i < self.t.size() {
            unsafe {
                yield self.at_(i) as *const T
            }

            i += 1
        }
    }

    /// Element `i`.
    priv inline fn at_(const self, i: usize) -> unsafe *T {
        return rt_entry<T>(self.t, i)
    }

    /// The index of `x`, or NO_ENTRY.
    priv inline fn find_(const self, const x: T) -> usize {
        var h           = hash_of(self.t, x)
        var slot: usize = 0
        return raw_find_slot(self.t, x, h, sizeof T, alignof T, &slot)
    }

    /// `insert`, as a member of the class itself: the extension blocks call
    /// it on a set they hold.
    priv inline fn insert_(self, x: T) -> bool {
        var h           = hash_of(self.t, x)
        var slot: usize = 0
        if raw_find_slot(self.t, x, h, sizeof T, alignof T, &slot) != NO_ENTRY {
            return false
        }

        var i = rt_link<T>(&self.t, h, slot)
        unsafe {
            __builtin_construct_at<T>(self.at_(i) as unsafe *u8, move(x))
        }

        rt_inserted<T, T>(&self.t)
        return true
    }

    /// Removes element `i`, which the caller has moved out of or not; the
    /// last element takes its place. `slot` names it.
    priv fn remove_at_(self, i: usize, slot: usize) {
        unsafe {
            __builtin_destruct_at(self.at_(i) as *T)
        }

        rt_remove_swap<T, T>(&self.t, slot, i)
    }

    priv inline fn same_(const self, const o: HashSet<T>) -> bool {
        unsafe {
            return (&self as unsafe *const u8) == (&o as unsafe *const u8)
        }
    }

    /// Keeps the elements whose membership in `o` is `in_o`, in order. The
    /// lookups run while entries move, so `o` must not be this set.
    priv fn filter_(self, const o: HashSet<T>, in_o: bool) {
        var n        = self.t.size()
        var w: usize = 0
        var r: usize = 0
        while r < n {
            unsafe {
                var unsafe *p = self.at_(r)
                if (o.find_(*p) != NO_ENTRY) == in_o {
                    if w != r {
                        rt_relocate<T>(self.at_(w), p)
                    }

                    w += 1
                } else {
                    __builtin_destruct_at(p as *T)
                }
            }

            r += 1
        }

        if w != n {
            rt_compact_end<T, T>(&self.t, w)
        }
    }

    /// Every element is in `o`. Short-circuits on size.
    priv fn subset_(const self, const o: HashSet<T>) -> bool {
        if self.t.size() > o.t.size() {
            return false
        }

        var i: usize = 0
        while i < self.t.size() {
            unsafe {
                if o.find_(*self.at_(i)) == NO_ENTRY {
                    return false
                }
            }

            i += 1
        }

        return true
    }

    /// The number of elements of `o` not in this set.
    priv fn count_missing_(const self, const o: HashSet<T>) -> usize {
        var c: usize = 0
        var i: usize = 0
        while i < o.t.size() {
            unsafe {
                if self.find_(*o.at_(i)) == NO_ENTRY {
                    c += 1
                }
            }

            i += 1
        }

        return c
    }
}

extend <T impl Hash> HashSet<T> {
    pub static fn with_capacity(n: usize) -> Self {
        var s = HashSet<T>()
        rt_reserve<T>(&s.t, n)
        return s
    }

    /// From any foreign range a `for x in r` loop accepts whose elements
    /// are `T` (`cxx::std::unordered_set<T>`, `cxx::std::set<T>`, a C++
    /// vector, ...). Names no C++ type. See NOTES.md change 12 for the bound.
    pub static fn <R> from_range(const r: R) -> Self {
        // STUB-BLOCKED(unbounded-range): `for x in r` over a parameter with
        // no bound is SC095E ('const R' is not iterable), and R has no bound
        // to call through.
        __builtin_trap()
    }

    pub inline fn size(const self) -> usize {
        return self.t.size()
    }

    pub inline fn is_empty(const self) -> bool {
        return self.t.size() == 0
    }

    pub inline fn capacity(const self) -> usize {
        return self.t.capacity()
    }

    /// Room for `n` elements in all without growing. Never shrinks.
    pub fn reserve(self, n: usize) {
        rt_reserve<T>(&self.t, n)
    }

    /// The smallest block that holds the elements; an empty set frees its
    /// block.
    pub fn shrink_to_fit(self) {
        rt_shrink<T>(&self.t)
    }

    pub inline fn op in (const self, const x: T) -> bool {
        return self.find_(x) != NO_ENTRY
    }

    @hot_path pub inline fn contains(const self, const x: T) -> bool {
        return self.find_(x) != NO_ENTRY
    }

    /// The stored element equal to `x`.
    pub inline fn get(const self, const x: T) -> *const T? {
        var i = self.find_(x)
        if i == NO_ENTRY {
            return null
        }

        unsafe {
            return self.at_(i) as *const T
        }
    }

    pub fn first(const self) -> *const T? {
        if self.t.size() == 0 {
            return null
        }

        unsafe {
            return self.at_(0) as *const T
        }
    }

    pub fn last(const self) -> *const T? {
        if self.t.size() == 0 {
            return null
        }

        unsafe {
            return self.at_(self.t.size() - 1) as *const T
        }
    }

    /// False, and `x` is dropped, when an equal element is already there.
    pub inline fn insert(self, x: T) -> bool {
        return self.insert_(move(x))
    }

    /// Inserts `x`, or puts it in the place of the equal element and returns
    /// that one.
    pub fn replace(self, x: T) -> T? {
        var h           = hash_of(self.t, x)
        var slot: usize = 0
        var i = raw_find_slot(self.t, x, h, sizeof T, alignof T, &slot)
        if i != NO_ENTRY {
            unsafe {
                var unsafe *p      = self.at_(i)
                var        old: T? = move(*p)
                *p = move(x)
                return old
            }
        }

        var j = rt_link<T>(&self.t, h, slot)
        unsafe {
            __builtin_construct_at<T>(self.at_(j) as unsafe *u8, move(x))
        }

        rt_inserted<T, T>(&self.t)
        return null
    }

    /// Removes `x`; the last element takes its place. O(1).
    pub fn swap_remove(self, const x: T) -> bool {
        var h           = hash_of(self.t, x)
        var slot: usize = 0
        var i = raw_find_slot(self.t, x, h, sizeof T, alignof T, &slot)
        if i == NO_ENTRY {
            return false
        }

        // `x` may be the stored element: nothing reads it after the destroy.
        self.remove_at_(i, slot)
        return true
    }

    /// Removes `x`; later elements shift down, so insertion order is kept.
    /// O(n).
    pub fn shift_remove(self, const x: T) -> bool {
        var i = self.find_(x)
        if i == NO_ENTRY {
            return false
        }

        unsafe {
            __builtin_destruct_at(self.at_(i) as *T)
        }

        rt_remove_shift<T>(&self.t, i)
        return true
    }

    /// Removes the element equal to `x` and returns it; the last element
    /// takes its place. O(1).
    pub fn take(self, const x: T) -> T? {
        var h           = hash_of(self.t, x)
        var slot: usize = 0
        var i = raw_find_slot(self.t, x, h, sizeof T, alignof T, &slot)
        if i == NO_ENTRY {
            return null
        }

        unsafe {
            var out: T? = move(*self.at_(i))
            self.remove_at_(i, slot)
            return out
        }
    }

    /// Removes the last element. O(1).
    pub fn pop(self) -> T? {
        var n = self.t.size()
        if n == 0 {
            return null
        }

        unsafe {
            var unsafe *p      = self.at_(n - 1)
            var        h       = hash_of(self.t, *p)
            var        out: T? = move(*p)
            __builtin_destruct_at(p as *T)
            rt_remove_last(&self.t, h)
            return out
        }
    }

    /// Keeps the elements `keep` accepts, in order. `keep` sees each element
    /// once, front to back. O(n).
    pub fn retain(self, keep: fn(*const T) -> bool) {
        var n        = self.t.size()
        var w: usize = 0
        var r: usize = 0
        while r < n {
            unsafe {
                var unsafe *p = self.at_(r)
                if keep(p as *const T) {
                    if w != r {
                        rt_relocate<T>(self.at_(w), p)
                    }

                    w += 1
                } else {
                    __builtin_destruct_at(p as *T)
                }
            }

            r += 1
        }

        if w != n {
            rt_compact_end<T, T>(&self.t, w)
        }
    }

    /// Destroys every element; the capacity stays.
    pub fn clear(self) {
        rt_clear<T>(&self.t)
    }

    pub fn items(const self) -> [const T;] {
        unsafe {
            return Slice<const T>(self.at_(0) as unsafe *const T, self.t.size())
        }
    }

    /// The elements of `self`, then those of `o` not in `self`.
    pub fn set_union(const self, const o: Self) -> yield *const T {
        var i: usize = 0
        while i < self.t.size() {
            unsafe {
                yield self.at_(i) as *const T
            }

            i += 1
        }

        var j: usize = 0
        while j < o.t.size() {
            unsafe {
                var unsafe *p = o.at_(j)
                if self.find_(*p) == NO_ENTRY {
                    yield p as *const T
                }
            }

            j += 1
        }
    }

    /// The elements in both, in the order of the smaller set (of `self` when
    /// the sizes are equal), pointing into that set.
    pub fn set_intersection(const self, const o: Self) -> yield *const T {
        var small = &self
        var large = &o
        if o.t.size() < self.t.size() {
            small = &o
            large = &self
        }

        var i: usize = 0
        while i < small->t.size() {
            unsafe {
                var unsafe *p = small->at_(i)
                if large->find_(*p) != NO_ENTRY {
                    yield p as *const T
                }
            }

            i += 1
        }
    }

    /// The elements of `self` not in `o`.
    pub fn set_difference(const self, const o: Self) -> yield *const T {
        var i: usize = 0
        while i < self.t.size() {
            unsafe {
                var unsafe *p = self.at_(i)
                if o.find_(*p) == NO_ENTRY {
                    yield p as *const T
                }
            }

            i += 1
        }
    }

    /// The elements of `self` not in `o`, then those of `o` not in `self`.
    pub fn set_xor(const self, const o: Self) -> yield *const T {
        var i: usize = 0
        while i < self.t.size() {
            unsafe {
                var unsafe *p = self.at_(i)
                if o.find_(*p) == NO_ENTRY {
                    yield p as *const T
                }
            }

            i += 1
        }

        var j: usize = 0
        while j < o.t.size() {
            unsafe {
                var unsafe *p = o.at_(j)
                if self.find_(*p) == NO_ENTRY {
                    yield p as *const T
                }
            }

            j += 1
        }
    }

    /// Keeps the elements also in `o`, in order.
    pub fn op &= (self, const o: Self) {
        if !self.same_(o) {
            self.filter_(o, true)
        }
    }

    /// Removes the elements in `o`, keeping the order of the rest.
    pub fn op -= (self, const o: Self) {
        if self.same_(o) {
            rt_clear<T>(&self.t)
        } else {
            self.filter_(o, false)
        }
    }

    pub fn is_subset(const self, const o: Self) -> bool {
        return self.subset_(o)
    }

    pub fn is_superset(const self, const o: Self) -> bool {
        return o.subset_(self)
    }

    /// Walks the smaller set.
    pub fn is_disjoint(const self, const o: Self) -> bool {
        var small = &self
        var large = &o
        if o.t.size() < self.t.size() {
            small = &o
            large = &self
        }

        var i: usize = 0
        while i < small->t.size() {
            unsafe {
                if large->find_(*small->at_(i)) != NO_ENTRY {
                    return false
                }
            }

            i += 1
        }

        return true
    }

    /// The same elements; order does not take part.
    pub fn op == (const self, const o: Self) -> bool {
        return self.t.size() == o.t.size() && self.subset_(o)
    }
}

extend <T impl Hash> HashSet<T> requires T impl Copyable {
    /// Deep. The index is copied as bytes: element order and positions are
    /// the same, so nothing is hashed.
    pub fn copy(const self) -> Self { // deep
        var s = HashSet<T>()
        var n = self.t.size()
        if n == 0 {
            return s
        }

        s.t.copy_index_from(self.t, sizeof T, alignof T)
        var unsafe *src = self.at_(0)
        var unsafe *dst = s.at_(0)
        eval if __builtin_is_trivially_copyable<T>() && __builtin_is_trivially_destructible<T>() {
            unsafe {
                __builtin_copy(
                    dst as unsafe *u8,
                    src as unsafe *const u8,
                    n * sizeof T,
                )
            }

            s.t.set_size(n)
        } else {
            var i: usize = 0
            while i < n {
                unsafe {
                    __builtin_construct_at<T>(
                        (dst + i) as unsafe *u8,
                        set_copy_of(src[i]),
                    )
                }

                i += 1
                s.t.set_size(i)
            }
        }

        return s
    }

    pub static fn from_slice(const items: [const T;]) -> Self {
        var s = HashSet<T>()
        set_extend_from(&s, items)
        return s
    }

    pub fn extend_from(self, const items: [const T;]) {
        set_extend_from(&self, items)
    }

    /// Copies in the elements of `o` this set lacks, in `o`'s order.
    pub fn op |= (self, const o: Self) { // copies o's elements in
        if self.same_(o) {
            return
        }

        rt_reserve<T>(&self.t, self.t.size() + self.count_missing_(o))
        var i: usize = 0
        while i < o.t.size() {
            unsafe {
                var unsafe *p = o.at_(i)
                if self.find_(*p) == NO_ENTRY {
                    self.insert_(set_copy_of(*p))
                }
            }

            i += 1
        }
    }

    /// Removes the elements in both and copies in those only `o` has: the
    /// survivors keep their order, then `o`'s, in `o`'s order.
    pub fn op ^= (self, const o: Self) {
        if self.same_(o) {
            rt_clear<T>(&self.t)
            return
        }

        var n0 = self.t.size()
        rt_reserve<T>(&self.t, n0 + self.count_missing_(o))
        // Appended elements are `o`'s and distinct, so the lookups below
        // still see `self` as it was for the elements of `o`.
        var i: usize = 0
        while i < o.t.size() {
            unsafe {
                var unsafe *p = o.at_(i)
                if self.find_(*p) == NO_ENTRY {
                    self.insert_(set_copy_of(*p))
                }
            }

            i += 1
        }

        var n        = self.t.size()
        var w: usize = 0
        var r: usize = 0
        while r < n {
            unsafe {
                var unsafe *p = self.at_(r)
                if r >= n0 || o.find_(*p) == NO_ENTRY {
                    if w != r {
                        rt_relocate<T>(self.at_(w), p)
                    }

                    w += 1
                } else {
                    __builtin_destruct_at(p as *T)
                }
            }

            r += 1
        }

        if w != n {
            rt_compact_end<T, T>(&self.t, w)
        }
    }
}

extend <T impl Hash> HashSet<T> impl FromIterator<T> {
    static fn <J impl Iterator> from_iter(it:   J,
                                          hint: usize) -> Self requires __builtin_is_same<J::Item, T>() {
        var s = HashSet<T>()
        rt_reserve<T>(&s.t, hint)
        loop {
            var x = it.next()
            if !x? {
                break
            }

            s.insert_(rt_mv_item<J>(unwrap!(x)))
        }

        return s
    }
}

/// Copies each element in.
priv fn <T impl Hash> set_extend_from(s:           *HashSet<T>,
                                      const items: [const T;]) requires T impl Copyable {
    var        n    = items.count_()
    var unsafe *src = items.first_()
    rt_reserve<T>(&s->t, s->t.size() + n)
    var i: usize = 0
    while i < n {
        unsafe {
            s->insert_(set_copy_of(*(src + i)))
        }

        i += 1
    }
}
