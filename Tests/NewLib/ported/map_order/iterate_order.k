// The order every way of walking a HashMap<K, V> reports: `for (k, v) in m`,
// keys(), values(), values_mut(), the entries() slice by index and by
// iterator, forward and backward, on empty, one-entry and large maps, on a
// const map, on a moved map, and after growth; writes through the value
// pointers leave the order alone; an entry's position in entries() matches
// its place in every other view.
//
// Backward walking exists only through the entries() slice (its iterator is
// double ended) or by index: keys(), values() and the pair loop are
// forward-only generators.
//
// differs from C++ and Rust: iteration order is defined (hash_map.k, the doc
// comment on HashMap).
//
// Cases from indexmap src/map/tests.rs (keys, values, values_mut, into_keys, into_values, iter_default, insert_order, get_index_mut2, last_mut)
// Cases from indexmap tests/quick.rs (keys_values, keys_values_mut, reverse, insertion_order)
// Cases from indexmap tests/tests.rs (test_sort: the order after construction)

import std::iter::*
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

/// Keys through the four forward views; the text says so when they differ.
fn ks(const m: {u64: u64}) -> string {
    var a = ""
    var b = ""
    var c = ""
    var d = ""
    for k in m.keys() { a += f"{*k} " }
    for (k, v) in m { b += f"{k} " }
    for e in m.entries() { c += f"{e.key} " }
    for var i: usize = 0; i < m.entries().size(); i += 1 { d += f"{m.entries()[i].key} " }
    if a != b || a != c || a != d { return f"MISMATCH keys[{a}] pairs[{b}] entries[{c}] indexed[{d}]" }
    return a
}

fn vs(const m: {u64: u64}) -> string {
    var a = ""
    var b = ""
    for v in m.values() { a += f"{*v} " }
    for (k, v) in m { b += f"{v} " }
    if a != b { return f"MISMATCH values[{a}] pairs[{b}]" }
    return a
}

/// The keys, from the last entry to the first, by index and by iterator.
fn back(const m: {u64: u64}) -> string {
    var a = ""
    var i = m.entries().size()
    while i > 0 {
        i -= 1
        a += f"{m.entries()[i].key} "
    }
    var b = iter(m.entries().iter()).rev().fold<string>("", cat_key)
    if a != b { return f"MISMATCH index[{a}] rev[{b}]" }
    return a
}

fn cat_key(acc: string, e: *const MapEntry<u64, u64>) -> string {
    acc += f"{e->key} "
    return acc
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

fn read_only(const m: {u64: u64}) -> string {
    var a = ""
    for (k, v) in m { a += f"{k}:{v} " }
    return a
}

fn test_empty_and_one() {
    var m: {u64: u64}
    ck(ks(m) == "" && vs(m) == "" && back(m) == "", "empty: every view is empty")
    ck(read_only(m) == "", "empty: const map")
    m.insert(7, 70)
    ck(ks(m) == "7 " && vs(m) == "70 " && back(m) == "7 ", "one entry: forward and backward")
    m.swap_remove(7)
    ck(ks(m) == "" && back(m) == "", "one entry removed: empty again")
}

fn test_forward_and_backward() {
    var m: {u64: u64}
    for var i: u64 = 0; i < 9; i += 1 { m.insert(i * 4 % 9, i) }
    // Keys 0 4 8 3 7 2 6 1 5 with values 0..8.
    ck(ks(m) == "0 4 8 3 7 2 6 1 5 ", "forward: keys")
    ck(vs(m) == "0 1 2 3 4 5 6 7 8 ", "forward: values")
    ck(back(m) == "5 1 6 2 7 3 8 4 0 ", "backward: keys, by index and by iterator")
    var counted = iter(m.entries().iter()).rev().enumerate().fold<u64>(0, enum_sum)
    ck(counted == 8 * 0 + 7 * 1 + 6 * 2 + 5 * 3 + 4 * 4 + 3 * 5 + 2 * 6 + 1 * 7 + 0 * 8, "backward: enumerate counts from the back")
    var forward_pos = iter(m.entries().iter()).enumerate().fold<u64>(0, enum_key_pos)
    ck(forward_pos == 0 * 0 + 1 * 4 + 2 * 8 + 3 * 3 + 4 * 7 + 5 * 2 + 6 * 6 + 7 * 1 + 8 * 5, "forward: position times key, summed")
}

fn enum_sum(acc: u64, p: (usize, *const MapEntry<u64, u64>)) -> u64 {
    return acc + (p.0 as u64) * p.1->value
}

fn enum_key_pos(acc: u64, p: (usize, *const MapEntry<u64, u64>)) -> u64 {
    return acc + (p.0 as u64) * p.1->key
}

fn test_values_mut_and_pointers() {
    var m: {u64: u64}
    for var i: u64 = 0; i < 6; i += 1 { m.insert(10 - i, i) }
    var seen = ""
    for v in m.values_mut() {
        seen += f"{*v} "
        *v = *v * 100
    }
    ck(seen == "0 1 2 3 4 5 ", "values_mut: visits in insertion order")
    ck(ks(m) == "10 9 8 7 6 5 " && vs(m) == "0 100 200 300 400 500 ", "values_mut: writes leave the key order alone")
    var visited = ""
    for (const *k, *v) in m {
        visited += f"{*k} "
        *v += *k
    }
    ck(visited == "10 9 8 7 6 5 " && vs(m) == "10 109 208 307 406 505 ", "pair loop: pointer writes in place, in order")
    var good = true
    var i: u64 = 0
    for (k, v) in m {
        if k != 10 - i { good = false }
        i += 1
    }
    ck(good && i == 6, "pair loop by value: same order")
}

fn test_const_moved_and_grown() {
    var a: {u64: u64} = {9: 1, 3: 2, 6: 3}
    ck(read_only(a) == "9:1 3:2 6:3 ", "const map: order")
    var b = a
    ck(ks(b) == "9 3 6 " && vs(b) == "1 2 3 ", "moved map: order kept")
    var big: {u64: u64}
    var good = true
    for var i: u64 = 0; i < 20000; i += 1 {
        big.insert(i * 40503 % 1000003, i)
        if i % 997 == 0 {
            // Every growth point: the walk is still in insertion order.
            var j: u64 = 0
            for (k, v) in big {
                if v != j || k != j * 40503 % 1000003 { good = false }
                j += 1
            }
            if j != i + 1 { good = false }
        }
    }
    ck(good, "growth: every view stays in insertion order while the map grows to 20000")
    var rev_ok = true
    var pos = big.entries().size()
    for e in big.entries() {
        pos -= 1
        if big.entries()[pos].value != big.size() as u64 - 1 - e.value { rev_ok = false }
    }
    ck(rev_ok, "growth: backward index matches forward")
}

fn test_nested_walk() {
    var m: {u64: u64} = {5: 50, 2: 20, 9: 90, 4: 40}
    var pairs = ""
    for (a, av) in m {
        for (b, bv) in m {
            if a < b { pairs += f"{a}{b} " }
        }
    }
    ck(pairs == "59 25 29 24 45 49 ", "nested walk of one map: both loops in insertion order")
}

fn test_entry_matches_lookup() {
    var m: {u64: u64}
    for var i: u64 = 0; i < 300; i += 1 { m.insert(i * 977 % 1009, i) }
    var good = true
    var pos: usize = 0
    for const *e in m.entries() {
        var *p? = m.get(e->key)
        var en? = m.get_entry(e->key)
        if !p? || *p != e->value || !en? || en->key != e->key || en->value != e->value { good = false }
        if m.entries()[pos].key != e->key { good = false }
        pos += 1
    }
    ck(good && pos == 300, "entries: each entry equals get and get_entry of its key")
}

fn test_strings() {
    var m: {string: string}
    m.insert("gamma".copy(), "3".copy())
    m.insert("alpha".copy(), "1".copy())
    m.insert("beta".copy(), "2".copy())
    var k = ""
    var v = ""
    for (const *a, const *b) in m {
        k += f"{*a} "
        v += f"{*b} "
    }
    ck(k == "gamma alpha beta " && v == "3 1 2 ", "strings: pair loop")
    k = ""
    for const *a in m.keys() { k += f"{*a} " }
    v = ""
    for const *b in m.values() { v += f"{*b} " }
    ck(k == "gamma alpha beta " && v == "3 1 2 ", "strings: keys and values")
    for *b in m.values_mut() { b->push_str("!") }
    v = ""
    for const *b in m.values() { v += f"{*b} " }
    ck(v == "3! 1! 2! ", "strings: values_mut appends in place")
    var r = ""
    var i = m.entries().size()
    while i > 0 {
        i -= 1
        r += f"{m.entries()[i].key} "
    }
    ck(r == "beta alpha gamma ", "strings: backward")
}

fn test_counted() {
    live = 0
    errors = 0
    {
        var m: {u64: Obj}
        for var i: u64 = 0; i < 12; i += 1 { m.insert(i * 5 % 12, Obj(i)) }
        var order = ""
        for (const *k, const *v) in m { order += f"{*k}:{v->v} " }
        ck(order == "0:0 5:1 10:2 3:3 8:4 1:5 6:6 11:7 4:8 9:9 2:10 7:11 ", "counted: pair loop")
        for *v in m.values_mut() { v->v += 100 }
        order = ""
        for const *e in m.entries() { order += f"{e->key}:{e->value.v} " }
        ck(order == "0:100 5:101 10:102 3:103 8:104 1:105 6:106 11:107 4:108 9:109 2:110 7:111 ", "counted: values_mut then entries")
        var i = m.entries().size()
        var good = true
        while i > 0 {
            i -= 1
            if m.entries()[i].value.v != 100 + i as u64 { good = false }
        }
        ck(good && live == 12, "counted: backward index, no object made or lost by walking")
    }
    ck(live == 0 && errors == 0, "counted: nothing leaked, nothing destroyed twice")
}

fn main() -> i32 {
    test_empty_and_one()
    test_forward_and_backward()
    test_values_mut_and_pointers()
    test_const_moved_and_grown()
    test_nested_walk()
    test_entry_matches_lookup()
    test_strings()
    test_counted()
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
