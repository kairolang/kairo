/// builtin/containers/hash_map.k

import base::cmp::*
import base::copy::*
import base::hash::*
import base::intrinsics::*
import base::iter::*
import builtin::Null
import containers::raw_table::*
import containers::slice::*

pub class <K, V> MapEntry {
    pub var key:   K
    pub var value: V
}

/// Insertion-ordered. Two words. MOVE-ONLY: `copy()` duplicates.
///   m[k]         reads; traps on a miss
///   m[k] = v     sets: replaces the value, or inserts (the setter form)
///   m[k] += 1    goes through the place form and inserts V::make_default() on a miss
/// Both write forms copy `k` only on a miss; `insert(k, v)` moves a key in.
@relocatable
pub class <K impl Hash, V> HashMap {
    priv var t: RawTable

    pub fn HashMap(self) {
        __builtin_trap() // BODY-TODO
    }

    @move pub fn HashMap(self, other: Self) {
        __builtin_trap() // BODY-TODO
    }

    pub fn op finally(self) {
        __builtin_trap() // BODY-TODO
    }

    @hot_path pub fn op []  (const self, const k: K) -> *const V {
        __builtin_trap() // BODY-TODO
    }

    pub fn op []= (self, const k: K, v: V)   requires K impl Copyable {
        __builtin_trap() // BODY-TODO
    }

    pub fn op []= (self, const k: K) -> *V   requires K impl Copyable && V impl Default {
        __builtin_trap() // BODY-TODO
    }

    pub fn op in (self) -> yield (*const K, *V) {
        __builtin_trap() // BODY-TODO
    }

    pub fn op in (const self) -> yield (*const K, *const V) {
        __builtin_trap() // BODY-TODO
    }
}

extend <K impl Hash, V> HashMap<K, V> {
    /// From any foreign range of pairs a `for p in r` loop accepts
    /// (`cxx::std::unordered_map<K, V>`, `cxx::std::map<K, V>`, a vector of
    /// `cxx::std::pair<K, V>`): each element's `first` is the key and
    /// `second` the value; a later key replaces an earlier one. Names no
    /// C++ type. See NOTES.md change 12 for the bound.
    pub static fn <R> from_pairs(const r: R) -> Self {
        __builtin_trap() // BODY-TODO
    }

    pub static fn with_capacity(n: usize) -> Self {
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

    pub fn op in (const self, const k: K) -> bool {
        __builtin_trap() // BODY-TODO
    }

    @hot_path pub fn contains(const self, const k: K) -> bool {
        __builtin_trap() // BODY-TODO
    }

    @hot_path pub fn get(const self, const k: K) -> *const V? {
        __builtin_trap() // BODY-TODO
    }

    pub fn get_mut(self, const k: K) -> *V? {
        __builtin_trap() // BODY-TODO
    }

    pub fn get_entry(const self, const k: K) -> *const MapEntry<K, V>? {
        __builtin_trap() // BODY-TODO
    }

    pub fn first(const self) -> *const MapEntry<K, V>? {
        __builtin_trap() // BODY-TODO
    }

    pub fn last(const self) -> *const MapEntry<K, V>? {
        __builtin_trap() // BODY-TODO
    }

    pub fn insert(self, k: K, v: V) -> V? { // the value it replaced
        __builtin_trap() // BODY-TODO
    }

    pub fn try_insert(self, k: K, v: V) -> V? { // null on success; v back when the key exists
        __builtin_trap() // BODY-TODO
    }

    pub fn get_or_insert(self, k: K, v: V) -> *V {
        __builtin_trap() // BODY-TODO
    }

    pub fn get_or_insert_with(self, k: K, make: fn() -> V) -> *V {
        __builtin_trap() // BODY-TODO
    }

    pub fn swap_remove(self, const k: K) -> V? {
        __builtin_trap() // BODY-TODO
    }

    pub fn shift_remove(self, const k: K) -> V? {
        __builtin_trap() // BODY-TODO
    }

    pub fn pop(self) -> (K, V)? {
        __builtin_trap() // BODY-TODO
    }

    pub fn retain(self, keep: fn(*const K, *V) -> bool) {
        __builtin_trap() // BODY-TODO
    }

    pub fn merge(self, other: Self, resolve: fn(V, V) -> V) { // consumes other
        __builtin_trap() // BODY-TODO
    }

    pub fn clear(self) {
        __builtin_trap() // BODY-TODO
    }

    pub fn entries(const self) -> [const MapEntry<K, V>;] {
        __builtin_trap() // BODY-TODO
    }

    pub fn keys(const self) -> yield *const K {
        __builtin_trap() // BODY-TODO
    }

    pub fn values(const self) -> yield *const V {
        __builtin_trap() // BODY-TODO
    }

    pub fn values_mut(self) -> yield *V {
        __builtin_trap() // BODY-TODO
    }
}

extend <K impl Hash, V impl Default> HashMap<K, V> {
    pub fn get_or_default(self, k: K) -> *V {
        __builtin_trap() // BODY-TODO
    }
}

extend <K impl Hash, V impl Copyable> HashMap<K, V> {
    pub fn get_or(const self, const k: K, const fallback: V) -> V {
        __builtin_trap() // BODY-TODO
    }
}

extend <K impl Hash, V impl Copyable> HashMap<K, V> requires K impl Copyable {
    pub fn copy(const self) -> Self { // deep
        __builtin_trap() // BODY-TODO
    }

    pub static fn from_slice(const items: [const (K, V);]) -> Self {
        __builtin_trap() // BODY-TODO
    }

    pub fn extend_from(self, const items: [const (K, V);]) {
        __builtin_trap() // BODY-TODO
    }
}

extend <K impl Hash, V> HashMap<K, V> impl FromIterator<(K, V)> {
    static fn <J impl Iterator> from_iter(it:   J,
                                          hint: usize) -> Self requires __builtin_is_same<J::Item, (K, V)>() {
        __builtin_trap() // BODY-TODO
    }
}
