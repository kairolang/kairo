// What a removal does to the order of a HashMap<K, V>: swap_remove moves the
// last entry into the gap, shift_remove closes the gap and keeps the order
// of the rest, pop takes the last entry, retain keeps the survivors in
// order and shows each entry once from the front, clear then reuse starts a
// fresh order. Each sequence is checked against a vector of keys that
// removes by the same rule (Vector.swap_remove, Vector.remove).
//
// differs from C++ and Rust: removal order effects are defined (hash_map.k:
// "Removes `k`; the last entry takes its place" on swap_remove, "later
// entries shift down, so insertion order is kept" on shift_remove).
//
// Cases from indexmap src/map/tests.rs (remove, remove_to_empty, swap_remove_index, shift_remove_entry, shift_remove_full, shift_shift_remove_index, clear)
// Cases from indexmap tests/quick.rs (insert_remove, pop, shift_remove, retain_ordered, operations_i8 with the Remove operations)
// Cases from indexmap src/set/tests.rs (remove, swap_take, shift_take, take)

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

/// The keys in order, read through keys(), the for loop and entries().
fn ks(const m: {u64: u64}) -> string {
    var a = ""
    var b = ""
    var c = ""
    for k in m.keys() { a += f"{*k} " }
    for (k, v) in m { b += f"{k} " }
    for e in m.entries() { c += f"{e.key} " }
    if a != b || a != c { return f"MISMATCH keys[{a}] pairs[{b}] entries[{c}]" }
    return a
}

fn kv(const m: {u64: u64}) -> string {
    var a = ""
    for (k, v) in m { a += f"{k}={v} " }
    return a
}

fn ends(const m: {u64: u64}) -> bool {
    if m.size() == 0 { return !m.first()? && !m.last()? }
    var f? = m.first()
    var l? = m.last()
    return f? && l? && f->key == m.entries()[0].key && l->key == m.entries()[m.size() - 1].key
}

/// The keys of `v` as text, in order.
fn show(const v: [u64]) -> string {
    var a = ""
    for x in v { a += f"{x} " }
    return a
}

fn from_keys(const keys: [u64]) -> {u64: u64} {
    var m: {u64: u64}
    for x in keys { m.insert(x, x * 10) }
    return m
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

var visited: [u64]

fn visit_all(k: *const u64, v: *u64) -> bool {
    visited.push(*k)
    return true
}

fn visit_odd(k: *const u64, v: *u64) -> bool {
    visited.push(*k)
    return *k % 2 == 1
}

fn drop_all(k: *const u64, v: *u64) -> bool { return false }
fn keep_all(k: *const u64, v: *u64) -> bool { return true }
fn keep_even_value(k: *const u64, v: *u64) -> bool { return *v % 20 == 0 }
fn keep_small(k: *const u64, v: *u64) -> bool { return *k < 10 }
fn keep_and_bump(k: *const u64, v: *u64) -> bool {
    *v += 1
    return *k % 3 != 0
}

fn keep_obj_odd(k: *const u64, v: *Obj) -> bool { return v->v % 2 == 1 }

fn test_swap_remove_moves_last() {
    var m = from_keys([10, 20, 30, 40, 50])
    var out? = m.swap_remove(20)
    ck(out? && out == 200 && ks(m) == "10 50 30 40 ", "swap_remove in the middle: the last entry takes the place")
    ck(kv(m) == "10=100 50=500 30=300 40=400 " && ends(m), "swap_remove: values travel with their keys")
    out = m.swap_remove(10)
    ck(out? && out == 100 && ks(m) == "40 50 30 ", "swap_remove of the first: the last entry becomes first")
    out = m.swap_remove(30)
    ck(out? && out == 300 && ks(m) == "40 50 ", "swap_remove of the last: nothing moves")
    out = m.swap_remove(99)
    ck(!out? && ks(m) == "40 50 ", "swap_remove of a missing key: null, order unchanged")
    out = m.swap_remove(40)
    ck(ks(m) == "50 " && out? && out == 400 && ends(m), "swap_remove down to one entry")
    out = m.swap_remove(50)
    ck(out? && out == 500 && ks(m) == "" && ends(m) && m.is_empty(), "swap_remove down to empty")
    out = m.swap_remove(50)
    ck(!out? && m.is_empty(), "swap_remove on an empty map")
}

fn test_shift_remove_keeps_order() {
    var m = from_keys([10, 20, 30, 40, 50])
    var out? = m.shift_remove(20)
    ck(out? && out == 200 && ks(m) == "10 30 40 50 ", "shift_remove in the middle: the rest keep their order")
    out = m.shift_remove(10)
    ck(out? && out == 100 && ks(m) == "30 40 50 ", "shift_remove of the first")
    out = m.shift_remove(50)
    ck(out? && out == 500 && ks(m) == "30 40 " && ends(m), "shift_remove of the last")
    out = m.shift_remove(99)
    ck(!out? && ks(m) == "30 40 ", "shift_remove of a missing key: null, order unchanged")
    out = m.shift_remove(30)
    out = m.shift_remove(40)
    ck(out? && m.is_empty() && ends(m), "shift_remove down to empty")
}

fn test_swap_sequence_against_vector() {
    // The sequence of positions the removal takes; the key at that position
    // is removed from the map, the position from the vector.
    var insert: [u64] = [0, 4, 2, 12, 8, 7, 11, 5, 3, 17, 19, 22, 23]
    var seq: [usize] = [3, 3, 10, 4, 5, 4, 3, 0, 1]
    var m = from_keys(insert)
    var model = [u64]::from_slice(insert)
    for var i: usize = 0; i < seq.size(); i += 1 {
        var key = model[seq[i]]
        var gone = model.swap_remove(seq[i])
        var out? = m.swap_remove(gone)
        ck(gone == key && out? && out == key * 10, "swap sequence: the removed value")
        ck(ks(m) == show(model) && ends(m), f"swap sequence: order after step {i}")
    }
    ck(m.size() == model.size() && m.size() == 4, "swap sequence: size")
}

fn test_shift_sequence_against_vector() {
    var insert: [u64] = [0, 4, 2, 12, 8, 7, 11, 5, 3, 17, 19, 22, 23]
    var seq: [usize] = [3, 3, 10 - 4, 4, 5 - 3, 0, 2, 1, 0]
    var m = from_keys(insert)
    var model = [u64]::from_slice(insert)
    for var i: usize = 0; i < seq.size(); i += 1 {
        var gone = model.remove(seq[i])
        var out? = m.shift_remove(gone)
        ck(out? && out == gone * 10, "shift sequence: the removed value")
        ck(ks(m) == show(model) && ends(m), f"shift sequence: order after step {i}")
    }
}

fn test_remove_all_orders() {
    for var form: u64 = 0; form < 2; form += 1 {
        // From the front, from the back, and from the middle outwards.
        for var order: u64 = 0; order < 3; order += 1 {
            var keys: [u64]
            for var i: u64 = 0; i < 200; i += 1 { keys.push(i * 31 % 200 + 1000) }
            var m = from_keys(keys)
            var model = [u64]::from_slice(keys)
            var good = true
            while model.size() > 0 {
                var pos: usize = 0
                if order == 1 { pos = model.size() - 1 }
                if order == 2 { pos = model.size() / 2 }
                var gone: u64
                if form == 0 { gone = model.swap_remove(pos) } else { gone = model.remove(pos) }
                var out? = if form == 0 => m.swap_remove(gone) else => m.shift_remove(gone)
                if !out? || out != gone * 10 { good = false }
                if show(model) != ks(m) || !ends(m) { good = false }
                if !good { break }
            }
            ck(good && m.is_empty(), f"remove all, form {form}, order {order}: order after every step")
        }
    }
}

fn test_pop_order() {
    var m = from_keys([5, 3, 9, 1])
    var p? = m.pop()
    ck(p? && p.0 == 1 && p.1 == 10 && ks(m) == "5 3 9 ", "pop: the last entry, with its value")
    m.swap_remove(5)
    ck(ks(m) == "9 3 ", "pop then swap_remove: the last takes the place")
    p = m.pop()
    ck(p? && p.0 == 3 && ks(m) == "9 ", "pop after swap_remove: the entry the swap moved last")
    m.insert(4, 40)
    p = m.pop()
    ck(p? && p.0 == 4 && p.1 == 40 && ks(m) == "9 ", "pop after insert: the new key")
    p = m.pop()
    ck(p? && p.0 == 9 && m.is_empty(), "pop down to empty")
    p = m.pop()
    ck(!p? && m.is_empty() && ends(m), "pop on an empty map returns null")
    var big: {u64: u64}
    for var i: u64 = 0; i < 3000; i += 1 { big.insert(i * 13, i) }
    var good = true
    for var i: u64 = 3000; i > 0; i -= 1 {
        var q? = big.pop()
        if !q? || q.0 != (i - 1) * 13 || q.1 != i - 1 { good = false }
    }
    ck(good && big.is_empty(), "pop 3000: reverse insertion order")
}

fn test_retain_order() {
    var m = from_keys([1, 2, 3, 4, 5, 6, 7, 8, 9])
    visited = []
    m.retain(visit_odd)
    ck(show(visited) == "1 2 3 4 5 6 7 8 9 ", "retain: each entry is shown once, front to back")
    ck(ks(m) == "1 3 5 7 9 " && ends(m), "retain: the survivors keep their order")
    visited = []
    m.retain(visit_all)
    ck(show(visited) == "1 3 5 7 9 " && ks(m) == "1 3 5 7 9 ", "retain that keeps everything: nothing moves")
    m.retain(keep_small)
    ck(ks(m) == "1 3 5 7 9 ", "retain by key keeping all small keys")
    m.retain(drop_all)
    ck(ks(m) == "" && m.is_empty() && ends(m), "retain that drops everything")
    m.retain(keep_all)
    ck(m.is_empty(), "retain on an empty map")
    m = from_keys([40, 7, 90, 31, 20, 5])
    m.retain(keep_even_value)
    ck(ks(m) == "40 90 20 " && kv(m) == "40=400 90=900 20=200 ", "retain by value: survivors in order with their values")
    m.retain(keep_and_bump)
    ck(ks(m) == "40 20 " && kv(m) == "40=401 20=201 ", "retain: the keep function writes values in place, a dropped entry's write is gone")
    // First dropped, last dropped, only the middle kept.
    m = from_keys([1, 2, 3, 4, 5])
    m.retain(keep_middle)
    ck(ks(m) == "2 3 4 ", "retain: the first and the last dropped")
    m = from_keys([1, 2, 3])
    m.insert(4, 40)
    m.retain(keep_small)
    m.insert(2, 5)
    m.insert(11, 5)
    ck(ks(m) == "1 2 3 4 11 ", "retain then insert: existing keys keep their place, a new key appends")
}

fn keep_middle(k: *const u64, v: *u64) -> bool { return *k > 1 && *k < 5 }

fn test_retain_large() {
    var m: {u64: u64}
    for var i: u64 = 0; i < 5000; i += 1 { m.insert(i * 2654435761 % 1000003, i) }
    var model: [u64]
    for (k, v) in m { if v % 3 != 0 { model.push(k) } }
    m.retain(keep_third_values)
    ck(ks(m) == show(model), "retain 5000: survivors in order")
    var good = true
    for k in model { if !m.contains(k) { good = false } }
    ck(good && m.size() == model.size(), "retain 5000: every survivor is found after the compaction")
}

fn keep_third_values(k: *const u64, v: *u64) -> bool { return *v % 3 != 0 }

fn test_clear_then_reuse() {
    var m = from_keys([5, 4, 3])
    var cap = m.capacity()
    m.clear()
    ck(ks(m) == "" && ends(m) && m.size() == 0 && m.capacity() == cap, "clear: no entries, the capacity stays")
    ck(!m.contains(5) && !m.get(4)? && !m.pop()?, "clear: nothing is found, nothing pops")
    m.insert(3, 1)
    m.insert(4, 2)
    m.insert(5, 3)
    ck(ks(m) == "3 4 5 " && kv(m) == "3=1 4=2 5=3 ", "clear then reuse: the order follows the new inserts")
    m.clear()
    m.clear()
    ck(m.is_empty(), "clear twice")
    for var round: u64 = 0; round < 20; round += 1 {
        for var i: u64 = 0; i < 100; i += 1 { m.insert((i * 7 + round) % 100 + round * 1000, i) }
        var first_key = round * 1000 + round % 100
        var f? = m.first()
        if !f? || f->key != first_key { ck(false, f"clear reuse round {round}: first key") }
        m.clear()
    }
    ck(m.is_empty(), "clear then refill 20 rounds")
}

fn test_interleaved() {
    var m: {u64: u64}
    var model: [u64]
    var good = true
    for var i: u64 = 0; i < 400; i += 1 {
        var k = i * 17 % 61
        if i % 3 == 2 {
            var at? = model.index_of(k)
            if at? {
                var pos: usize = at
                if i % 2 == 0 { model.swap_remove(pos); m.swap_remove(k) } else { model.remove(pos); m.shift_remove(k) }
            }
        } else if !model.contains(k) {
            model.push(k)
            m.insert(k, i)
        } else {
            m.insert(k, i)
        }
        if ks(m) != show(model) { good = false; break }
    }
    ck(good, "interleaved inserts and both removals: order equals the vector model")
}

fn test_strings() {
    var m: {string: u64}
    m.insert("a".copy(), 1)
    m.insert("b".copy(), 2)
    m.insert("c".copy(), 3)
    m.insert("d".copy(), 4)
    var out? = m.swap_remove("a")
    var order = ""
    for const *k in m.keys() { order += f"{*k} " }
    ck(out? && out == 1 && order == "d b c ", "strings: swap_remove moves the last")
    out = m.shift_remove("b")
    order = ""
    for const *k in m.keys() { order += f"{*k} " }
    ck(out? && out == 2 && order == "d c ", "strings: shift_remove keeps the order")
    var p? = m.pop()
    ck(p? && p.0 == "c" && p.1 == 3, "strings: pop")
    var s: {string: string}
    for var i: u64 = 0; i < 50; i += 1 { s.insert(f"key{i}", f"val{i}") }
    s.retain(keep_str_even)
    var good = true
    var j: u64 = 0
    for (const *k, const *v) in s {
        if *k != f"key{j}" || *v != f"val{j}" { good = false }
        j += 2
    }
    ck(good && s.size() == 25, "strings: retain keeps every other entry, in order")
}

var tick: u64 = 0

/// Keeps the first, third, ... entry shown.
fn keep_str_even(k: *const string, v: *string) -> bool {
    tick += 1
    return tick % 2 == 1
}

fn test_counted() {
    live = 0
    errors = 0
    {
        var m: {u64: Obj}
        for var i: u64 = 0; i < 30; i += 1 { m.insert(i, Obj(i)) }
        var o? = m.swap_remove(3)
        ck(o? && o.v == 3 && live == 30, "counted: swap_remove hands the value out")
        o = null
        ck(live == 29, "counted: the handed-out value dies when dropped")
        var last? = m.last()
        ck(last? && last->key == 28 && m.entries()[3].key == 29, "counted: order after swap_remove")
        o = m.shift_remove(0)
        ck(o? && o.v == 0 && m.entries()[0].key == 1, "counted: shift_remove keeps the order")
        o = null
        var p? = m.pop()
        ck(p? && p.0 == 28 && p.1.v == 28, "counted: pop")
        p = null
        m.retain(keep_obj_odd)
        ck(m.size() == 14 && live == 14, "counted: retain destroys the dropped entries")
        var good = true
        for const *e in m.entries() {
            if e->value.v % 2 != 1 { good = false }
        }
        ck(good, "counted: survivors hold the right values")
        m.clear()
        ck(live == 0, "counted: clear")
    }
    ck(live == 0 && errors == 0, "counted: nothing leaked, nothing destroyed twice")
}

fn main() -> i32 {
    test_swap_remove_moves_last()
    test_shift_remove_keeps_order()
    test_swap_sequence_against_vector()
    test_shift_sequence_against_vector()
    test_remove_all_orders()
    test_pop_order()
    test_retain_order()
    test_retain_large()
    test_clear_then_reuse()
    test_interleaved()
    test_strings()
    test_counted()
    io::println(f"{checks} checks, {failures} failures")
    return failures as i32
}

// --- lit wiring ---
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: {{[0-9]+}} checks, 0 failures
