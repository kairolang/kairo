/// builtin/containers/hash_map.k

import base::cmp::*
import base::copy::*
import base::hash::*
import base::intrinsics::*
import base::iter::*
import builtin::Null
import containers::raw_table::*
import containers::slice::*
import string::*

pub class <K, V> MapEntry {
    pub var key:   K
    pub var value: V
}

/// A lookup with `m[k]` found no entry. One copy for every map type.
@cold_path @no_inline
priv fn key_fail() -> ! {
    __builtin_trap()
}

priv inline fn <T impl Copyable> map_copy_of(const x: T) -> T {
    return x.copy()
}

/// Insertion-ordered. Two words. MOVE-ONLY: `copy()` duplicates.
///   m[k]         reads; traps on a miss
///   m[k] = v     sets: replaces the value, or inserts (the setter form)
///   m[k] += 1    goes through the place form and inserts V::make_default() on a miss
/// Both write forms copy `k` only on a miss; `insert(k, v)` moves a key in.
///
/// A map literal is built as `HashMap()`, `reserve(n)`, then `insert(k, v)`
/// per entry in written order, so a repeated key keeps its first place and
/// takes its last value.
///
/// Any insert may move every entry (growth), and any removal moves at least
/// one: a pointer from a lookup, a place form or an iteration is good until
/// the next insert or removal.
@relocatable
pub class <K impl Hash, V> HashMap {
    priv var t: RawTable

    pub fn HashMap(self) { }

    @move pub fn HashMap(self, other: Self) {
        self.t.steal(&other.t)
    }

    pub fn op finally(self) {
        rt_release<MapEntry<K, V>>(&self.t)
    }

    /// Entry `i`.
    priv inline fn ent(const self, i: usize) -> unsafe *MapEntry<K, V> {
        return rt_entry<MapEntry<K, V>>(self.t, i)
    }

    /// The entry index of `k`, or NO_ENTRY.
    priv inline fn find_(const self, const k: K) -> usize {
        var h           = hash_of(self.t, k)
        var slot: usize = 0
        return raw_find_slot(
            self.t,
            k,
            h,
            sizeof MapEntry<K, V>,
            alignof MapEntry<K, V>,
            &slot,
        )
    }

    /// A new entry for `k` at the end, linked under `h` into `slot` (where
    /// the miss stopped). Returns its address, uninitialized.
    priv inline fn add_(self, h: u64, slot: usize) -> unsafe *u8 {
        var i = rt_link<MapEntry<K, V>>(&self.t, h, slot)
        unsafe {
            return self.ent(i) as unsafe *u8
        }
    }

    /// `insert`, as a member of the class itself: the extension blocks call
    /// it on a map they hold.
    priv inline fn insert_(self, k: K, v: V) -> V? {
        var h           = hash_of(self.t, k)
        var slot: usize = 0
        var e = raw_find_slot(
            self.t,
            k,
            h,
            sizeof MapEntry<K, V>,
            alignof MapEntry<K, V>,
            &slot,
        )

        if e != NO_ENTRY {
            unsafe {
                var unsafe *p      = self.ent(e)
                var        old: V? = rt_mv_v(p->value)
                p->value = rt_mv_v(v)
                return old
            }
        }

        unsafe {
            __builtin_construct_at<MapEntry<K, V>>(
                self.add_(h, slot),
                rt_mv_k(k),
                rt_mv_v(v),
            )
        }

        rt_inserted<MapEntry<K, V>, K>(&self.t)
        return null
    }

    @hot_path pub inline fn op []  (const self, const k: K) -> *const V {
        var e = self.find_(k)
        @unlikely
        if e == NO_ENTRY {
            key_fail()
        }

        unsafe {
            return &self.ent(e)->value as unsafe *const V as *const V
        }
    }

    pub inline fn op []= (self, const k: K, v: V)   requires K impl Copyable {
        var h           = hash_of(self.t, k)
        var slot: usize = 0
        var e = raw_find_slot(
            self.t,
            k,
            h,
            sizeof MapEntry<K, V>,
            alignof MapEntry<K, V>,
            &slot,
        )

        unsafe {
            if e != NO_ENTRY {
                var unsafe *p = self.ent(e)
                p->value = rt_mv_v(v)
                return
            }

            __builtin_construct_at<MapEntry<K, V>>(
                self.add_(h, slot),
                map_key_copy(k),
                rt_mv_v(v),
            )
        }

        rt_inserted<MapEntry<K, V>, K>(&self.t)
    }

    pub inline fn op []= (self, const k: K) -> *V   requires K impl Copyable && V impl Default {
        var h           = hash_of(self.t, k)
        var slot: usize = 0
        var e = raw_find_slot(
            self.t,
            k,
            h,
            sizeof MapEntry<K, V>,
            alignof MapEntry<K, V>,
            &slot,
        )

        if e == NO_ENTRY {
            e = self.t.size()
            unsafe {
                __builtin_construct_at<MapEntry<K, V>>(
                    self.add_(h, slot),
                    map_key_copy(k),
                    map_value_default<V>(),
                )
            }

            rt_inserted<MapEntry<K, V>, K>(&self.t)
        }

        unsafe {
            return &self.ent(e)->value as unsafe *V as *V
        }
    }

    pub fn op in (self) -> yield (*const K, *V) {
        var i: usize = 0
        while i < self.t.size() {
            unsafe {
                var unsafe *e = self.ent(i)
                var kv = (&e->key as unsafe *const K as *const K, &e->value as unsafe *V as *V)
                yield kv
            }

            i += 1
        }
    }

    pub fn op in (const self) -> yield (*const K, *const V) {
        var i: usize = 0
        while i < self.t.size() {
            unsafe {
                var unsafe *e = self.ent(i)
                var kv = (
                    &e->key as unsafe *const K as *const K,
                    &e->value as unsafe *const V as *const V,
                )

                yield kv
            }

            i += 1
        }
    }
}

extend <K impl Hash, V> HashMap<K, V> {
    /// From any foreign range of pairs a `for p in r` loop accepts
    /// (`cxx::std::unordered_map<K, V>`, `cxx::std::map<K, V>`, a vector of
    /// `cxx::std::pair<K, V>`): each element's `first` is the key and
    /// `second` the value; a later key replaces an earlier one. Names no
    /// C++ type. See NOTES.md change 12 for the bound.
    pub static fn <R> from_pairs(const r: R) -> Self {
        // STUB-BLOCKED(unbounded-range): `for p in r` over a parameter with
        // no bound is SC095E ('const R' is not iterable), and R has no bound
        // to call through.
        __builtin_trap()
    }

    pub static fn with_capacity(n: usize) -> Self {
        var m = HashMap<K, V>()
        rt_reserve<MapEntry<K, V>>(&m.t, n)
        return m
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

    /// Room for `n` entries in all without growing. Never shrinks.
    pub fn reserve(self, n: usize) {
        rt_reserve<MapEntry<K, V>>(&self.t, n)
    }

    /// The smallest block that holds the entries; an empty map frees its
    /// block.
    pub fn shrink_to_fit(self) {
        rt_shrink<MapEntry<K, V>>(&self.t)
    }

    pub inline fn op in (const self, const k: K) -> bool {
        return self.find_(k) != NO_ENTRY
    }

    @hot_path pub inline fn contains(const self, const k: K) -> bool {
        return self.find_(k) != NO_ENTRY
    }

    @hot_path pub inline fn get(const self, const k: K) -> *const V? {
        var e = self.find_(k)
        if e == NO_ENTRY {
            return null
        }

        unsafe {
            return &self.ent(e)->value as unsafe *const V as *const V
        }
    }

    pub inline fn get_mut(self, const k: K) -> *V? {
        var e = self.find_(k)
        if e == NO_ENTRY {
            return null
        }

        unsafe {
            return &self.ent(e)->value as unsafe *V as *V
        }
    }

    pub fn get_entry(const self, const k: K) -> *const MapEntry<K, V>? {
        var e = self.find_(k)
        if e == NO_ENTRY {
            return null
        }

        unsafe {
            return self.ent(e) as *const MapEntry<K, V>
        }
    }

    pub fn first(const self) -> *const MapEntry<K, V>? {
        if self.t.size() == 0 {
            return null
        }

        unsafe {
            return self.ent(0) as *const MapEntry<K, V>
        }
    }

    pub fn last(const self) -> *const MapEntry<K, V>? {
        if self.t.size() == 0 {
            return null
        }

        unsafe {
            return self.ent(self.t.size() - 1) as *const MapEntry<K, V>
        }
    }

    /// Inserts or replaces; a replaced entry keeps its place and the key
    /// already stored.
    pub inline fn insert(self, k: K, v: V) -> V? { // the value it replaced
        return self.insert_(rt_mv_k(k), rt_mv_v(v))
    }

    pub fn try_insert(self, k: K, v: V) -> V? { // null on success; v back when the key exists
        var h           = hash_of(self.t, k)
        var slot: usize = 0
        var e = raw_find_slot(
            self.t,
            k,
            h,
            sizeof MapEntry<K, V>,
            alignof MapEntry<K, V>,
            &slot,
        )

        if e != NO_ENTRY {
            var back: V? = rt_mv_v(v)
            return back
        }

        unsafe {
            __builtin_construct_at<MapEntry<K, V>>(
                self.add_(h, slot),
                rt_mv_k(k),
                rt_mv_v(v),
            )
        }

        rt_inserted<MapEntry<K, V>, K>(&self.t)
        return null
    }

    pub fn get_or_insert(self, k: K, v: V) -> *V {
        var h           = hash_of(self.t, k)
        var slot: usize = 0
        var e = raw_find_slot(
            self.t,
            k,
            h,
            sizeof MapEntry<K, V>,
            alignof MapEntry<K, V>,
            &slot,
        )

        if e == NO_ENTRY {
            e = self.t.size()
            unsafe {
                __builtin_construct_at<MapEntry<K, V>>(
                    self.add_(h, slot),
                    rt_mv_k(k),
                    rt_mv_v(v),
                )
            }

            rt_inserted<MapEntry<K, V>, K>(&self.t)
        }

        unsafe {
            return &self.ent(e)->value as unsafe *V as *V
        }
    }

    /// `make` runs only on a miss.
    pub fn get_or_insert_with(self, k: K, make: fn() -> V) -> *V {
        var h           = hash_of(self.t, k)
        var slot: usize = 0
        var e = raw_find_slot(
            self.t,
            k,
            h,
            sizeof MapEntry<K, V>,
            alignof MapEntry<K, V>,
            &slot,
        )

        if e == NO_ENTRY {
            // Before the link: `make` may not see a half-built entry.
            var v = make()
            e = self.t.size()
            unsafe {
                __builtin_construct_at<MapEntry<K, V>>(
                    self.add_(h, slot),
                    rt_mv_k(k),
                    rt_mv_v(v),
                )
            }

            rt_inserted<MapEntry<K, V>, K>(&self.t)
        }

        unsafe {
            return &self.ent(e)->value as unsafe *V as *V
        }
    }

    /// Removes `k`; the last entry takes its place. O(1).
    pub inline fn swap_remove(self, const k: K) -> V? {
        var h           = hash_of(self.t, k)
        var slot: usize = 0
        var e = raw_find_slot(
            self.t,
            k,
            h,
            sizeof MapEntry<K, V>,
            alignof MapEntry<K, V>,
            &slot,
        )

        if e == NO_ENTRY {
            return null
        }

        // `k` may be the stored key: nothing reads it after the destroy.
        unsafe {
            var unsafe *p      = self.ent(e)
            var        out: V? = rt_mv_v(p->value)
            __builtin_destruct_at(p as *MapEntry<K, V>)
            rt_remove_swap<MapEntry<K, V>, K>(&self.t, slot, e)
            return out
        }
    }

    /// Removes `k`; later entries shift down, so insertion order is kept.
    /// O(n).
    pub fn shift_remove(self, const k: K) -> V? {
        var e = self.find_(k)
        if e == NO_ENTRY {
            return null
        }

        unsafe {
            var unsafe *p      = self.ent(e)
            var        out: V? = rt_mv_v(p->value)
            __builtin_destruct_at(p as *MapEntry<K, V>)
            rt_remove_shift<MapEntry<K, V>>(&self.t, e)
            return out
        }
    }

    /// Removes the last entry. O(1).
    pub fn pop(self) -> (K, V)? {
        var n = self.t.size()
        if n == 0 {
            return null
        }

        unsafe {
            var unsafe *p           = self.ent(n - 1)
            var        h            = hash_of(self.t, p->key)
            var        out: (K, V)? = (rt_mv_k(p->key), rt_mv_v(p->value))
            __builtin_destruct_at(p as *MapEntry<K, V>)
            rt_remove_last(&self.t, h)
            return out
        }
    }

    /// Keeps the entries `keep` accepts, in order. `keep` sees each entry
    /// once, front to back. O(n).
    pub fn retain(self, keep: fn(*const K, *V) -> bool) {
        var n        = self.t.size()
        var w: usize = 0
        var r: usize = 0
        while r < n {
            unsafe {
                var unsafe *p = self.ent(r)
                if keep(
                    &p->key as unsafe *const K as *const K,
                    &p->value as unsafe *V as *V,
                ) {
                    if w != r {
                        rt_relocate<MapEntry<K, V>>(self.ent(w), p)
                    }

                    w += 1
                } else {
                    __builtin_destruct_at(p as *MapEntry<K, V>)
                }
            }

            r += 1
        }

        if w != n {
            rt_compact_end<MapEntry<K, V>, K>(&self.t, w)
        }
    }

    /// Moves every entry of `other` in, in its order; where both have a key,
    /// the value becomes `resolve(mine, theirs)`.
    pub fn merge(self, other: Self, resolve: fn(V, V) -> V) { // consumes other
        var n        = other.t.size()
        var i: usize = 0
        while i < n {
            unsafe {
                var unsafe *p          = rt_entry<MapEntry<K, V>>(other.t, i)
                var        h           = hash_of(self.t, p->key)
                var        slot: usize = 0
                var e = raw_find_slot(
                    self.t,
                    p->key,
                    h,
                    sizeof MapEntry<K, V>,
                    alignof MapEntry<K, V>,
                    &slot,
                )

                if e != NO_ENTRY {
                    var unsafe *q = self.ent(e)
                    q->value = resolve(rt_mv_v(q->value), rt_mv_v(p->value))
                } else {
                    __builtin_construct_at<MapEntry<K, V>>(
                        self.add_(h, slot),
                        rt_mv_k(p->key),
                        rt_mv_v(p->value),
                    )

                    rt_inserted<MapEntry<K, V>, K>(&self.t)
                }
            }

            i += 1
        }

        // other's moved-from entries are destroyed with it.
    }

    /// Destroys every entry; the capacity stays.
    pub fn clear(self) {
        rt_clear<MapEntry<K, V>>(&self.t)
    }

    pub fn entries(const self) -> [const MapEntry<K, V>;] {
        unsafe {
            return Slice<const MapEntry<K, V>>(
                self.ent(0) as unsafe *const MapEntry<K, V>,
                self.t.size(),
            )
        }
    }

    pub fn keys(const self) -> yield *const K {
        var i: usize = 0
        while i < self.t.size() {
            unsafe {
                yield &self.ent(i)->key as unsafe *const K as *const K
            }

            i += 1
        }
    }

    pub fn values(const self) -> yield *const V {
        var i: usize = 0
        while i < self.t.size() {
            unsafe {
                yield &self.ent(i)->value as unsafe *const V as *const V
            }

            i += 1
        }
    }

    pub fn values_mut(self) -> yield *V {
        var i: usize = 0
        while i < self.t.size() {
            unsafe {
                yield &self.ent(i)->value as unsafe *V as *V
            }

            i += 1
        }
    }
}

extend <K impl Hash, V impl Default> HashMap<K, V> {
    pub fn get_or_default(self, k: K) -> *V {
        var h           = hash_of(self.t, k)
        var slot: usize = 0
        var e = raw_find_slot(
            self.t,
            k,
            h,
            sizeof MapEntry<K, V>,
            alignof MapEntry<K, V>,
            &slot,
        )

        if e == NO_ENTRY {
            e = self.t.size()
            unsafe {
                __builtin_construct_at<MapEntry<K, V>>(
                    self.add_(h, slot),
                    rt_mv_k(k),
                    V::make_default(),
                )
            }

            rt_inserted<MapEntry<K, V>, K>(&self.t)
        }

        unsafe {
            return &self.ent(e)->value as unsafe *V as *V
        }
    }
}

extend <K impl Hash, V impl Copyable> HashMap<K, V> {
    pub fn get_or(const self, const k: K, const fallback: V) -> V {
        var e = self.find_(k)
        if e == NO_ENTRY {
            return map_copy_of(fallback)
        }

        unsafe {
            return map_copy_of(self.ent(e)->value)
        }
    }
}

extend <K impl Hash, V impl Copyable> HashMap<K, V> requires K impl Copyable {
    /// Deep. The index is copied as bytes: entry order and positions are the
    /// same, so nothing is hashed.
    pub fn copy(const self) -> Self { // deep
        var m = HashMap<K, V>()
        var n = self.t.size()
        if n == 0 {
            return m
        }

        m.t.copy_index_from(
            self.t,
            sizeof MapEntry<K, V>,
            alignof MapEntry<K, V>,
        )

        var unsafe *src = self.ent(0)
        var unsafe *dst = m.ent(0)
        eval if __builtin_is_trivially_copyable<MapEntry<K, V>>() && __builtin_is_trivially_destructible<MapEntry<K, V>>() {
            unsafe {
                __builtin_copy(
                    dst as unsafe *u8,
                    src as unsafe *const u8,
                    n * sizeof MapEntry<K, V>,
                )
            }

            m.t.set_size(n)
        } else {
            var i: usize = 0
            while i < n {
                unsafe {
                    __builtin_construct_at<MapEntry<K, V>>(
                        (dst + i) as unsafe *u8,
                        map_copy_of(src[i].key),
                        map_copy_of(src[i].value),
                    )
                }

                i += 1
                m.t.set_size(i)
            }
        }

        return m
    }

    pub static fn from_slice(const items: [const (K, V);]) -> Self {
        var m = HashMap<K, V>()
        map_extend_from(&m, items)
        return m
    }

    /// Copies each pair in; a later key replaces an earlier one.
    pub fn extend_from(self, const items: [const (K, V);]) {
        map_extend_from(&self, items)
    }
}

// COMPILER-WORKAROUND(member-requires): a member's own `requires K impl
// Copyable` (or `V impl Default`) is not a bound inside its body (R051E at
// every call that needs it), and every generic function called there is
// instantiated for every map type, the branches of an `eval if` and the
// member's own clause notwithstanding. So the two `op []=` forms copy the
// key and make the value through helpers that compile for any type: a
// string by its copy(), any other copy-constructible key by its copy
// constructor, and a value by its default constructor. A key type that can
// only be copied by a copy() of its own traps in these two forms (insert
// moves a key in and is unaffected). With the member's clause granted,
// these are `map_copy_of(k)` and `V::make_default()`.
priv inline fn <K> map_key_copy(const k: K) -> K {
    eval if __builtin_is_same<K, string>() {
        unsafe {
            var c = (&k as unsafe *const string)->copy()
            return rt_mv_k(*(&c as unsafe *K))
        }
    } else if __builtin_is_constructible<K, const K>() {
        return k
    } else {
        __builtin_trap()
    }
}

priv inline fn <V> map_value_default() -> V {
    eval if __builtin_is_default_constructible<V>() {
        var v: V
        return v
    } else {
        __builtin_trap()
    }
}

extend <K impl Hash, V> HashMap<K, V> impl FromIterator<(K, V)> {
    /// A later key replaces an earlier one.
    static fn <J impl Iterator> from_iter(it:   J,
                                          hint: usize) -> Self requires __builtin_is_same<J::Item, (K, V)>() {
        var m = HashMap<K, V>()
        rt_reserve<MapEntry<K, V>>(&m.t, hint)
        loop {
            var x = it.next()
            if !x? {
                break
            }

            var pair: (K, V) = rt_mv_item<J>(unwrap!(x))
            m.insert_(rt_mv_k(pair.0), rt_mv_v(pair.1))
        }

        return m
    }
}

/// Copies each pair in; a later key replaces an earlier one.
priv fn <K impl Hash, V impl Copyable> map_extend_from(m:           *HashMap<K, V>,
                                                       const items: [const (K, V);]) requires K impl Copyable {
    var        n    = items.count_()
    var unsafe *src = items.first_()
    rt_reserve<MapEntry<K, V>>(&m->t, m->t.size() + n)
    var i: usize = 0
    while i < n {
        unsafe {
            m->insert_(map_copy_of((*(src + i)).0), map_copy_of((*(src + i)).1))
        }

        i += 1
    }
}
