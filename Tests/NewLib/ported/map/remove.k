// Removal members of HashMap<K, V>: swap_remove (the last entry takes the
// hole), shift_remove (later entries shift down, insertion order kept), pop
// (the last entry as a key and value pair), retain (each entry once, front
// to back, order kept) and clear (capacity kept), on empty, one-entry and
// many-entry maps, with integer, string and move-only counted elements.
//
// differs from C++: there is no erase by iterator or range, and no
// extract; a removal by key returns the value (`V?`), not a count. The order
// after a removal is Kairo's rule, from the doc comments in hash_map.k:
// swap_remove "the last entry takes its place", shift_remove "later entries
// shift down, so insertion order is kept".
//
// Cases from libc++ test/std/containers/unord/unord.map/unord.map.modifiers/ (erase_key, clear, erase_if)
// Cases from Rust library/std/src/collections/hash/map/tests.rs (retain, remove)
// Cases from hashbrown src/map.rs tests (remove, retain, empty remove)

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

class Obj {
    pub var v: u64
    var state: u64

    pub fn Obj(self, v: u64) {
        self.v = v
        self.state = 1
        live += 1
    }

    @move pub fn Obj(self, other: Self) {
        if other.state != 1 { errors += 1 }
        self.v = other.v
        self.state = 1
        other.state = 2
        live += 1
    }

    pub fn op finally(self) {
        if self.state == 0 { errors += 1 }
        self.state = 0
        live -= 1
    }
}

var visits: u64 = 0
var last_seen: u64 = 0
var order_ok: bool = true

fn keep_even(k: *const u64, v: *u64) -> bool {
    return *k % 2 == 0
}

fn keep_all(k: *const u64, v: *u64) -> bool { return true }

fn keep_none(k: *const u64, v: *u64) -> bool { return false }

fn keep_and_bump(k: *const u64, v: *u64) -> bool {
    *v += 1
    return *k % 3 != 0
}

fn watch(k: *const u64, v: *u64) -> bool {
    if visits > 0 && *k <= last_seen { order_ok = false }
    last_seen = *k
    visits += 1
    return true
}

fn keep_obj_even(k: *const u64, v: *Obj) -> bool {
    return v->v % 2 == 0
}

fn keys_of(const m: {u64: u64}) -> [u64] {
    var r: [u64]
    for (k, v) in m { r.push(k) }
    return r
}

fn test_remove_empty_and_one() {
    var m: {u64: u64}
    ck(!m.swap_remove(1)? && !m.shift_remove(1)? && !m.pop()?, "empty: removals return null")
    m.insert(1, 10)
    ck(!m.swap_remove(2)? && !m.shift_remove(2)? && m.size() == 1, "one: removing an absent key changes nothing")
    var r? = m.swap_remove(1)
    ck(r? && r == 10 && m.is_empty() && !m.contains(1), "one: swap_remove of the only entry")
    m.insert(1, 11)
    r = m.shift_remove(1)
    ck(r? && r == 11 && m.is_empty(), "one: shift_remove of the only entry")
    m.insert(2, 20)
    var p? = m.pop()
    ck(p? && p.0 == 2 && p.1 == 20 && m.is_empty() && !m.pop()?, "one: pop, then pop on empty")
    m.insert(1, 12)
    ck(m[1] == 12 && m.size() == 1, "one: reuse after emptying")
}

fn test_swap_remove_order() {
    // The last entry takes the removed entry's place (hash_map.k, swap_remove).
    var m: {u64: u64}
    for var i: u64 = 0; i < 6; i += 1 { m.insert(i, i * 10) }
    var r? = m.swap_remove(1)
    ck(r? && r == 10, "swap_remove: value")
    var ks = keys_of(m)
    ck(ks.size() == 5 && ks[0] == 0 && ks[1] == 5 && ks[2] == 2 && ks[3] == 3 && ks[4] == 4, "swap_remove: the last entry fills the hole")
    r = m.swap_remove(4)
    ks = keys_of(m)
    ck(r? && ks.size() == 4 && ks[3] == 3, "swap_remove of the last entry just drops it")
    r = m.swap_remove(0)
    ks = keys_of(m)
    ck(r? && ks[0] == 3 && ks.size() == 3, "swap_remove of the first entry")
    ck(m[3] == 30 && m[5] == 50 && m[2] == 20 && !m.contains(0), "swap_remove: remaining entries find their values")
}

fn test_shift_remove_order() {
    // Later entries shift down; insertion order is kept (hash_map.k, shift_remove).
    var m: {u64: u64}
    for var i: u64 = 0; i < 6; i += 1 { m.insert(i, i * 10) }
    var r? = m.shift_remove(1)
    var ks = keys_of(m)
    ck(r? && r == 10 && ks.size() == 5 && ks[0] == 0 && ks[1] == 2 && ks[2] == 3 && ks[3] == 4 && ks[4] == 5, "shift_remove: order kept")
    r = m.shift_remove(5)
    ks = keys_of(m)
    ck(r? && ks.size() == 4 && ks[3] == 4, "shift_remove of the last entry")
    r = m.shift_remove(0)
    ks = keys_of(m)
    ck(r? && ks[0] == 2 && ks[1] == 3 && ks[2] == 4, "shift_remove of the first entry")
    ck(m[2] == 20 && m[3] == 30 && m[4] == 40, "shift_remove: remaining entries find their values")
}

fn test_remove_many() {
    var m: {u64: u64}
    for var i: u64 = 0; i < 4000; i += 1 { m.insert(i, i) }
    var bad: u64 = 0
    for var i: u64 = 0; i < 4000; i += 2 {
        var r? = m.swap_remove(i)
        if !r? || r != i { bad += 1 }
    }
    ck(bad == 0 && m.size() == 2000, "many: swap_remove of every even key")
    for var i: u64 = 0; i < 4000; i += 1 {
        if m.contains(i) != (i % 2 == 1) { bad += 1 }
    }
    ck(bad == 0, "many: exactly the odd keys remain")
    for var i: u64 = 1; i < 4000; i += 4 {
        var r? = m.shift_remove(i)
        if !r? || r != i { bad += 1 }
    }
    ck(bad == 0 && m.size() == 1000, "many: shift_remove of every fourth key")
    var sh: {u64: u64}
    for var i: u64 = 0; i < 4000; i += 1 { sh.insert(i, i) }
    for var i: u64 = 0; i < 4000; i += 3 { sh.shift_remove(i) }
    var prev: u64 = 0
    var first = true
    for (k, v) in sh {
        if !first && k <= prev { bad += 1 }
        prev = k
        first = false
    }
    ck(bad == 0 && sh.size() == 4000 - 1334, "many: shift_remove keeps ascending insertion order")
    while m.size() > 0 {
        var p? = m.pop()
        if !p? || p.0 != p.1 { bad += 1 }
    }
    ck(bad == 0 && m.is_empty(), "many: pop until empty returns key and value together")
}

fn test_pop_order() {
    var m: {u64: u64}
    for var i: u64 = 0; i < 10; i += 1 { m.insert(i, i + 100) }
    var p? = m.pop()
    ck(p? && p.0 == 9 && p.1 == 109 && m.size() == 9, "pop: the last inserted entry")
    m.insert(50, 150)
    p = m.pop()
    ck(p? && p.0 == 50, "pop after an insert: the newest entry")
    m.insert(3, 999)
    p = m.pop()
    ck(p? && p.0 == 8, "pop after a replace: the replaced key kept its place")
}

fn test_insert_remove_cycles() {
    // Many insert/remove rounds on a map of constant size: removed slots are reused.
    // The block is sized for four times the steady size: a table at most half
    // full rebuilds its index in place when tombstones use up the room, and
    // only a fuller one doubles (raw_table.k, the header comment).
    var m: {u64: u64}
    var bad: u64 = 0
    m.reserve(256)
    for var i: u64 = 0; i < 64; i += 1 { m.insert(i, i) }
    var cap = m.capacity()
    for var round: u64 = 0; round < 5000; round += 1 {
        var r? = m.swap_remove(round)
        if !r? { bad += 1 }
        m.insert(round + 64, round + 64)
    }
    ck(bad == 0 && m.size() == 64, "cycles: size constant over 5000 replacements")
    for var i: u64 = 5000; i < 5064; i += 1 {
        if !m.contains(i) { bad += 1 }
    }
    ck(bad == 0 && m.capacity() == cap, "cycles: a steady size does not grow the block")
    for var round: u64 = 5000; round < 9000; round += 1 {
        var r? = m.shift_remove(round)
        if !r? { bad += 1 }
        m.insert(round + 64, round + 64)
    }
    ck(bad == 0 && m.size() == 64 && m.capacity() == cap, "cycles: shift_remove rounds")
    ck(m.entries()[0].key == 9000 && m.entries()[63].key == 9063, "cycles: shift_remove keeps order")
}

fn test_retain() {
    var m: {u64: u64}
    m.retain(keep_even)
    ck(m.is_empty(), "retain: empty map")
    for var i: u64 = 0; i < 10; i += 1 { m.insert(i, i) }
    m.retain(keep_all)
    ck(m.size() == 10, "retain: keep everything")
    m.retain(keep_even)
    var ks = keys_of(m)
    ck(ks.size() == 5 && ks[0] == 0 && ks[1] == 2 && ks[2] == 4 && ks[3] == 6 && ks[4] == 8, "retain: kept entries keep their order")
    ck(m[6] == 6 && !m.contains(7), "retain: kept entries find their values")
    m.retain(keep_and_bump)
    ck(m.size() == 3 && m[2] == 3 && m[4] == 5 && m[8] == 9 && !m.contains(0) && !m.contains(6), "retain: the callback may write the value")
    m.retain(keep_none)
    ck(m.is_empty() && !m.contains(2), "retain: drop everything")
    m.insert(1, 1)
    ck(m[1] == 1, "retain: a map reused after emptying")
    var w: {u64: u64}
    for var i: u64 = 0; i < 3000; i += 1 { w.insert(i, i) }
    visits = 0
    order_ok = true
    w.retain(watch)
    ck(visits == 3000 && order_ok && w.size() == 3000, "retain: the callback sees each entry once, front to back")
    w.retain(keep_even)
    var bad: u64 = 0
    for var i: u64 = 0; i < 3000; i += 1 {
        if w.contains(i) != (i % 2 == 0) { bad += 1 }
    }
    ck(bad == 0 && w.size() == 1500, "retain: many entries, every lookup agrees afterwards")
    w.insert(1, 5)
    ck(w.size() == 1501 && w[1] == 5 && w.entries()[1500].key == 1, "retain: insert after retain goes last")
}

fn test_clear() {
    var m: {u64: u64}
    m.clear()
    ck(m.is_empty(), "clear: empty map")
    for var i: u64 = 0; i < 100; i += 1 { m.insert(i, i) }
    var cap = m.capacity()
    m.clear()
    ck(m.size() == 0 && m.is_empty() && m.capacity() == cap, "clear: keeps the capacity (hash_map.k, clear)")
    ck(!m.contains(5) && !m.get(5)? && !m.first()? && !m.last()?, "clear: nothing is found")
    m.insert(5, 55)
    ck(m.size() == 1 && m[5] == 55 && m.entries()[0].key == 5, "clear: reuse")
    m.clear()
    m.clear()
    ck(m.is_empty(), "clear twice")
}

fn test_string_removal() {
    var m: {string: string}
    for var i: u64 = 0; i < 300; i += 1 { m.insert(f"key-{i}", f"value-{i}") }
    var r? = m.swap_remove("key-5")
    ck(r? && r == "value-5" && !m.contains("key-5"), "string: swap_remove")
    r = m.shift_remove("key-6")
    ck(r? && r == "value-6", "string: shift_remove")
    var p? = m.pop()
    ck(p? && p.0 == "key-298" && p.1 == "value-298", "string: pop gives the last entry after the swap and the shift")
    ck(p? && p.1.size() > 6, "string: popped value intact")
    m.retain(fn_keep_str)
    var bad: u64 = 0
    for (const *k, const *v) in m {
        if k->size() != 6 { bad += 1 }
    }
    ck(bad == 0 && m.size() > 0, "string: retain by key length")
    m.clear()
    ck(m.is_empty(), "string: clear")
}

fn fn_keep_str(k: *const string, v: *string) -> bool {
    return k->size() == 6
}

fn test_counted_removal() {
    {
        var m: {u64: Obj}
        for var i: u64 = 0; i < 100; i += 1 { m.insert(i, Obj(i)) }
        var r? = m.swap_remove(10)
        ck(r? && r.v == 10 && live == 100, "counted: swap_remove hands the object out, not destroyed")
        r = null
        ck(live == 99, "counted: dropping it destroys it")
        r = m.shift_remove(20)
        ck(r? && r.v == 20 && live == 99, "counted: shift_remove hands the object out")
        r = null
        ck(live == 98, "counted: dropped")
        var p? = m.pop()
        ck(p? && p.0 == 98 && p.1.v == 98 && live == 98, "counted: pop")
        p = null
        ck(live == 97, "counted: pop result dropped")
        m.retain(keep_obj_even)
        ck(live == m.size() as i64 && m.size() > 0, "counted: retain destroys exactly the dropped entries")
        var n = m.size()
        m.clear()
        ck(live == 0 && m.is_empty() && n > 0, "counted: clear destroys every entry")
        for var i: u64 = 0; i < 10; i += 1 { m.insert(i, Obj(i)) }
        ck(live == 10, "counted: reuse after clear")
    }
    ck(live == 0 && errors == 0, "remove: nothing leaked, nothing destroyed twice")
}

fn main() -> i32 {
    test_remove_empty_and_one()
    test_swap_remove_order()
    test_shift_remove_order()
    test_remove_many()
    test_pop_order()
    test_insert_remove_cycles()
    test_retain()
    test_clear()
    test_string_removal()
    test_counted_removal()
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
