// Order across the events that rebuild a HashMap's index: growth through
// every table size up to 200000 entries, reserve, with_capacity and
// shrink_to_fit, copy() of maps with removals in their history, a copy that
// then grows apart from its original, a moved map, and keys whose hash takes
// sixteen values or one value, where every probe sequence is long. Each
// result is compared with a vector of keys kept by the same rules.
//
// differs from C++ and Rust: copy() keeps entry positions (hash_map.k: "the
// index is copied as bytes: entry order and positions are the same").
//
// Cases from indexmap src/map/tests.rs (grow, reserve, shrink_to_fit, from_entries, remove, clear)
// Cases from indexmap tests/quick.rs (with_cap, insertion_order, operations_i8, operations_string)
// Cases from hashbrown src/map.rs tests (lots of insertions, conflict remove, clone)

import std::io

var checks: u64 = 0
var failures: u64 = 0
var live: i64 = 0
var errors: u64 = 0

fn ck(cond: bool, const what: string) {
    checks += 1
    if !cond {
        failures += 1
        io::println(f"FAIL {what}")
    }
}

/// True when the map's keys, in order, are exactly `model`.
fn same_keys(const m: {u64: u64}, const model: [u64]) -> bool {
    if m.size() != model.size() || m.entries().size() != model.size() { return false }
    var i: usize = 0
    for k in m.keys() {
        if *k != model[i] || m.entries()[i].key != *k { return false }
        i += 1
    }
    return i == model.size()
}

fn key_at(i: u64) -> u64 { return i * 0x9E3779B97F4A7C15 + 12345 }

fn test_growth_orders() {
    var m: {u64: u64}
    var model: [u64]
    var good = true
    var checked: u64 = 0
    for var i: u64 = 0; i < 200000; i += 1 {
        var k = key_at(i)
        m.insert(k, i)
        model.push(k)
        // At every power of two, and just past each one, compare the whole map.
        if (i & (i + 1)) == 0 || (i & (i - 1)) == 0 {
            if !same_keys(m, model) { good = false; break }
            checked += 1
        }
    }
    ck(good && checked > 30, "growth to 200000 entries: whole-map order at every table size")
    ck(same_keys(m, model), "growth: final order")
    var pairs_ok = true
    var j: u64 = 0
    for (k, v) in m {
        if v != j { pairs_ok = false }
        j += 1
    }
    ck(pairs_ok, "growth: values follow the same order")
    var first? = m.first()
    var last? = m.last()
    ck(first? && last? && first->key == key_at(0) && last->key == key_at(199999), "growth: first and last")
    // Every key is still found after all the rebuilds.
    var found = true
    for var i: u64 = 0; i < 200000; i += 997 {
        var *p? = m.get(key_at(i))
        if !p? || *p != i { found = false }
    }
    ck(found, "growth: lookups after the last rebuild")
}

fn test_reserve_and_shrink() {
    var m: {u64: u64}
    var model: [u64]
    for var i: u64 = 0; i < 1000; i += 1 {
        m.insert(key_at(i), i)
        model.push(key_at(i))
    }
    m.reserve(100000)
    ck(same_keys(m, model), "reserve: order kept")
    for var i: u64 = 1000; i < 1500; i += 1 {
        m.insert(key_at(i), i)
        model.push(key_at(i))
    }
    ck(same_keys(m, model), "insert into reserved room: order kept")
    m.shrink_to_fit()
    ck(same_keys(m, model), "shrink_to_fit: order kept")
    for var i: u64 = 0; i < 1400; i += 1 {
        var k = model.remove(0)
        m.shift_remove(k)
    }
    m.shrink_to_fit()
    ck(same_keys(m, model) && m.size() == 100, "shrink_to_fit after removals: the 100 left keep their order")
    var w = {u64: u64}::with_capacity(5000)
    for var i: u64 = 0; i < 5000; i += 1 { w.insert(key_at(i), i) }
    var wm: [u64]
    for var i: u64 = 0; i < 5000; i += 1 { wm.push(key_at(i)) }
    ck(same_keys(w, wm), "with_capacity: order is the insertion order")
    var e: {u64: u64}
    e.reserve(10)
    e.shrink_to_fit()
    e.insert(3, 3)
    e.insert(1, 1)
    ck(e.entries()[0].key == 3 && e.entries()[1].key == 1, "reserve and shrink on an empty map, then inserts")
}

fn test_copy_order() {
    var m: {u64: u64}
    var model: [u64]
    for var i: u64 = 0; i < 3000; i += 1 {
        m.insert(key_at(i), i)
        model.push(key_at(i))
    }
    // History: removals of both kinds before the copy.
    for var i: u64 = 0; i < 3000; i += 7 {
        var k = key_at(i)
        var at? = model.index_of(k)
        if at? {
            var pos: usize = at
            if i % 2 == 0 { model.swap_remove(pos); m.swap_remove(k) } else { model.remove(pos); m.shift_remove(k) }
        }
    }
    var c = m.copy()
    ck(same_keys(c, model) && same_keys(m, model), "copy after removals: same order, original untouched")
    var vals_ok = true
    for (k, v) in c {
        var *p? = m.get(k)
        if !p? || *p != v { vals_ok = false }
    }
    ck(vals_ok, "copy: same values")
    // The two are independent.
    c.insert(7, 7)
    c[model[0]] = 99
    m.swap_remove(model[1])
    ck(c.size() == model.size() + 1 && c.entries()[c.size() - 1].key == 7, "copy: an insert appends to the copy only")
    ck(m.size() == model.size() - 1 && m[model[0]] != 99, "copy: a write or removal in one is not seen in the other")
    var cc = c.copy()
    ck(cc.size() == c.size() && cc.entries()[cc.size() - 1].key == 7 && cc.entries()[0].key == c.entries()[0].key, "copy of a copy")
    // Grow both apart.
    for var i: u64 = 5000; i < 9000; i += 1 {
        c.insert(key_at(i), i)
        m.insert(key_at(i) + 1, i)
    }
    var cg = true
    var base = model.size()
    for var i: u64 = 0; i < 4000; i += 1 {
        if c.entries()[base + 1 + i as usize].key != key_at(5000 + i) { cg = false }
        if m.entries()[base - 1 + i as usize].key != key_at(5000 + i) + 1 { cg = false }
    }
    ck(cg, "copy: after growing apart each keeps its own order")
    var e: {u64: u64}
    var ec = e.copy()
    ck(ec.size() == 0 && !ec.first()? && !ec.last()?, "copy of an empty map")
    ec.insert(2, 2)
    ec.insert(1, 1)
    ck(ec.entries()[0].key == 2, "an empty map's copy takes inserts in order")
    var one: {u64: u64} = {5: 50}
    var oc = one.copy()
    ck(oc.size() == 1 && oc.entries()[0].key == 5 && oc[5] == 50, "copy of one entry")
}

fn test_moved() {
    var a: {u64: u64}
    for var i: u64 = 0; i < 1000; i += 1 { a.insert(key_at(i), i) }
    var b = a
    var model: [u64]
    for var i: u64 = 0; i < 1000; i += 1 { model.push(key_at(i)) }
    ck(same_keys(b, model), "moved map: order kept")
    b.insert(1, 1)
    model.push(1)
    ck(same_keys(b, model), "moved map: later inserts append")
    var c = make_map(600)
    var cm: [u64]
    for var i: u64 = 0; i < 600; i += 1 { cm.push(key_at(i)) }
    ck(same_keys(c, cm), "map returned from a function: order kept")
}

fn make_map(n: u64) -> {u64: u64} {
    var m: {u64: u64}
    for var i: u64 = 0; i < n; i += 1 { m.insert(key_at(i), i) }
    return m
}

fn test_strings_copy() {
    var m: {string: string}
    for var i: u64 = 0; i < 400; i += 1 { m.insert(f"key-{i * 37 % 401}", f"v{i}") }
    var c = m.copy()
    var good = c.size() == m.size()
    var i: u64 = 0
    for (const *k, const *v) in m {
        if *k != c.entries()[i as usize].key || *v != c.entries()[i as usize].value { good = false }
        if *k != f"key-{i * 37 % 401}" { good = false }
        i += 1
    }
    ck(good && i == 400, "strings: copy keeps order and values, strings are deep")
    m.shift_remove("key-0")
    ck(c.contains("key-0") && c.size() == 400 && m.size() == 399, "strings: the copy keeps what the original lost")
}

// How a key hashes, chosen per run: 0 writes v % 16, 1 writes nothing, 2
// writes v. Equality is by v.
var mode: u64 = 0

struct HKey {
    pub var v: u64
}

extend HKey impl Hash {
    fn hash(const self, @inout h: Hasher) {
        if mode == 0 {
            h.write_u64(self.v % 16)
        } else if mode == 2 {
            h.write_u64(self.v)
        }
    }

    fn op == (const self, const o: HKey) -> bool { return self.v == o.v }
}

extend HKey impl Copyable {
    fn copy(const self) -> HKey { return HKey { v: self.v } }
}

fn same_hkeys(const m: {HKey: u64}, const model: [u64]) -> bool {
    if m.size() != model.size() { return false }
    var i: usize = 0
    for (const *k, const *v) in m {
        if k->v != model[i] { return false }
        i += 1
    }
    return true
}

fn keep_thirds(k: *const HKey, v: *u64) -> bool { return k->v % 3 != 0 }
fn sum(a: u64, b: u64) -> u64 { return a + b }

fn test_collision_order() {
    for var m_i: u64 = 0; m_i < 3; m_i += 1 {
        mode = m_i
        var m: {HKey: u64}
        var model: [u64]
        var good = true
        for var i: u64 = 0; i < 1500; i += 1 {
            var k = i * 2654435761 % 100003
            m.insert(HKey { v: k }, i)
            if !model.contains(k) { model.push(k) }
        }
        if !same_hkeys(m, model) { good = false }
        ck(good, f"mode {m_i}: insertion order under collision")
        // Replacements keep the places.
        for var i: u64 = 0; i < 1500; i += 3 { m.insert(HKey { v: model[i as usize] }, 7) }
        ck(same_hkeys(m, model), f"mode {m_i}: replacing under collision keeps places")
        // Both removals.
        for var i: u64 = 0; i < 400; i += 1 {
            var pos = (i * 7) as usize % model.size()
            var gone = model.swap_remove(pos)
            m.swap_remove(HKey { v: gone })
            pos = (i * 11) as usize % model.size()
            gone = model.remove(pos)
            m.shift_remove(HKey { v: gone })
            if !same_hkeys(m, model) { good = false; break }
        }
        ck(good && m.size() == model.size(), f"mode {m_i}: removals under collision match the vector")
        var p? = m.pop()
        var q? = model.pop()
        ck(p? && q? && p.0.v == q, f"mode {m_i}: pop under collision")
        m.retain(keep_thirds)
        var kept: [u64]
        for x in model { if x % 3 != 0 { kept.push(x) } }
        ck(same_hkeys(m, kept), f"mode {m_i}: retain under collision")
        // Lookups, the reason the order matters: every key still found.
        var found = true
        for x in kept { if !m.contains(HKey { v: x }) { found = false } }
        ck(found, f"mode {m_i}: every kept key found")
        var c = m.copy()
        ck(same_hkeys(c, kept), f"mode {m_i}: copy under collision")
        var other: {HKey: u64}
        var add: [u64]
        for var i: u64 = 0; i < 300; i += 1 {
            var k = i * 3 + 1
            other.insert(HKey { v: k }, i)
        }
        for var i: u64 = 0; i < 300; i += 1 {
            var k = i * 3 + 1
            if !kept.contains(k) { add.push(k) }
        }
        m.merge(other, sum)
        var all = [u64]::from_slice(kept)
        for x in add { all.push(x) }
        ck(same_hkeys(m, all), f"mode {m_i}: merge under collision")
        m.clear()
        m.insert(HKey { v: 9 }, 1)
        m.insert(HKey { v: 1 }, 2)
        ck(m.size() == 2 && m.entries()[0].key.v == 9, f"mode {m_i}: clear then reuse")
    }
}

fn main() -> i32 {
    test_growth_orders()
    test_reserve_and_shrink()
    test_copy_order()
    test_moved()
    test_strings_copy()
    test_collision_order()
    io::println(f"{checks} checks, {failures} failures")
    return failures as i32
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: {{[0-9]+}} checks, 0 failures
