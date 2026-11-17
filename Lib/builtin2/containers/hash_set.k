/// builtin/containers/hash_set.k

import base::cmp::*
import base::copy::*
import base::hash::*
import base::intrinsics::*
import base::iter::*
import builtin::Null
import containers::raw_table::*
import containers::slice::*

/// Insertion-ordered. Two words. MOVE-ONLY: `copy()` duplicates.
@relocatable
pub class <T impl Hash> HashSet {
    priv var t: RawTable

    pub fn HashSet(self) {
        __builtin_trap() // BODY-TODO
    }

    @move pub fn HashSet(self, other: Self) {
        __builtin_trap() // BODY-TODO
    }

    pub fn op finally(self) {
        __builtin_trap() // BODY-TODO
    }

    pub fn op in (const self) -> yield *const T {
        __builtin_trap() // BODY-TODO
    }
}

extend <T impl Hash> HashSet<T> {
    pub static fn with_capacity(n: usize) -> Self {
        __builtin_trap() // BODY-TODO
    }

    /// From any foreign range a `for x in r` loop accepts whose elements
    /// are `T` (`cxx::std::unordered_set<T>`, `cxx::std::set<T>`, a C++
    /// vector, ...). Names no C++ type. See NOTES.md change 12 for the bound.
    pub static fn <R> from_range(const r: R) -> Self {
        __builtin_trap() // BODY-TODO
    }

    pub fn size(const self) -> usize {
        __builtin_trap() // BODY-TODO
    }

    pub fn is_empty(const self) -> bool {
        __builtin_trap() // BODY-TODO
    }

    pub fn capacity(const self) -> usize {
        __builtin_trap() // BODY-TODO
    }

    pub fn reserve(self, n: usize) {
        __builtin_trap() // BODY-TODO
    }

    pub fn shrink_to_fit(self) {
        __builtin_trap() // BODY-TODO
    }

    pub fn op in (const self, const x: T) -> bool {
        __builtin_trap() // BODY-TODO
    }

    @hot_path pub fn contains(const self, const x: T) -> bool {
        __builtin_trap() // BODY-TODO
    }

    pub fn get(const self, const x: T) -> *const T? {
        __builtin_trap() // BODY-TODO
    }

    pub fn first(const self) -> *const T? {
        __builtin_trap() // BODY-TODO
    }

    pub fn last(const self) -> *const T? {
        __builtin_trap() // BODY-TODO
    }

    pub fn insert(self, x: T) -> bool {
        __builtin_trap() // BODY-TODO
    }

    pub fn replace(self, x: T) -> T? {
        __builtin_trap() // BODY-TODO
    }

    pub fn swap_remove(self, const x: T) -> bool {
        __builtin_trap() // BODY-TODO
    }

    pub fn shift_remove(self, const x: T) -> bool {
        __builtin_trap() // BODY-TODO
    }

    pub fn take(self, const x: T) -> T? {
        __builtin_trap() // BODY-TODO
    }

    pub fn pop(self) -> T? {
        __builtin_trap() // BODY-TODO
    }

    pub fn retain(self, keep: fn(*const T) -> bool) {
        __builtin_trap() // BODY-TODO
    }

    pub fn clear(self) {
        __builtin_trap() // BODY-TODO
    }

    pub fn items(const self) -> [const T;] {
        __builtin_trap() // BODY-TODO
    }

    pub fn set_union(const self, const o: Self) -> yield *const T {
        __builtin_trap() // BODY-TODO
    }

    pub fn set_intersection(const self, const o: Self) -> yield *const T {
        __builtin_trap() // BODY-TODO
    }

    pub fn set_difference(const self, const o: Self) -> yield *const T {
        __builtin_trap() // BODY-TODO
    }

    pub fn set_xor(const self, const o: Self) -> yield *const T {
        __builtin_trap() // BODY-TODO
    }

    pub fn op &= (self, const o: Self) {
        __builtin_trap() // BODY-TODO
    }

    pub fn op -= (self, const o: Self) {
        __builtin_trap() // BODY-TODO
    }

    pub fn is_subset(const self, const o: Self) -> bool {
        __builtin_trap() // BODY-TODO
    }

    pub fn is_superset(const self, const o: Self) -> bool {
        __builtin_trap() // BODY-TODO
    }

    pub fn is_disjoint(const self, const o: Self) -> bool {
        __builtin_trap() // BODY-TODO
    }

    pub fn op == (const self, const o: Self) -> bool {
        __builtin_trap() // BODY-TODO
    }
}

extend <T impl Hash> HashSet<T> requires T impl Copyable {
    pub fn copy(const self) -> Self { // deep
        __builtin_trap() // BODY-TODO
    }

    pub static fn from_slice(const items: [const T;]) -> Self {
        __builtin_trap() // BODY-TODO
    }

    pub fn extend_from(self, const items: [const T;]) {
        __builtin_trap() // BODY-TODO
    }

    pub fn op |= (self, const o: Self) { // copies o's elements in
        __builtin_trap() // BODY-TODO
    }

    pub fn op ^= (self, const o: Self) {
        __builtin_trap() // BODY-TODO
    }
}

extend <T impl Hash> HashSet<T> impl FromIterator<T> {
    static fn <J impl Iterator> from_iter(it:   J,
                                          hint: usize) -> Self requires __builtin_is_same<J::Item, T>() {
        __builtin_trap() // BODY-TODO
    }
}
