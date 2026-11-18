// The order a HashSet<T> reports through every view, and what keeps it
// across the events that rebuild its index: the for loop and the items()
// slice forward and backward, positional reads (items()[i], get(i), at(i),
// ranges), the agreement of the hash index with the element array after
// every kind of insert and removal, growth through every table size up to
// 200000 elements, reserve, with_capacity and shrink_to_fit, copy() of sets
// with removals in their history, a copy that grows apart from its
// original, a moved set, and elements whose hash takes sixteen values or one
// value. A position past the end of items() traps.
//
// API gaps (indexmap set members with no Kairo counterpart): get_index_of /
// get_full / get_index; swap_remove_index / shift_remove_index;
// swap_indices; move_index; shift_insert; insert_full / insert_sorted /
// insert_before; replace_index; sort / sort_by / sort_unstable / sorted_by
// and the cached-key forms; binary_search / partition_point on the set;
// reverse; truncate; split_off; drain; get_range; is_sorted. Backward
// walking exists only through items() (its iterator is double ended) or by
// index.
//
// differs from C++ and Rust: copy() keeps element positions (hash_set.k:
// "the index is copied as bytes: element order and positions are the
// same").
//
// Cases from indexmap src/set/tests.rs (grow, reserve, shrink_to_fit, insert_order, first, last, get_range, from_array, iter_default)
// Cases from indexmap tests/quick.rs (insertion_order, with_cap, indexing, operations_i8)
// Cases from hashbrown src/set.rs tests (lots of insertions, clone)

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

fn same(const s: {u64}, const model: [u64]) -> bool {
    if s.size() != model.size() || s.items().size() != model.size() { return false }
    var i: usize = 0
    for x in s {
        if x != model[i] || s.items()[i] != x { return false }
        i += 1
    }
    return i == model.size()
}

fn key_at(i: u64) -> u64 { return i * 0x9E3779B97F4A7C15 + 12345 }

/// The hash index and the element array agree: the element a lookup finds
/// for the value at position i is the one stored at i.
fn consistent(const s: {u64}) -> bool {
    var n = s.items().size()
    if n != s.size() { return false }
    for var i: usize = 0; i < n; i += 1 {
        var g? = s.get(s.items()[i])
        if !g? { return false }
        if g != &s.items()[i] { return false }
    }
    return true
}

fn cat_item(acc: string, x: *const u64) -> string {
    acc += f"{*x} "
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

extend Obj impl Hash {
    fn hash(const self, @inout h: Hasher) { h.write_u64(self.v) }
    fn op == (const self, const o: Obj) -> bool { return self.v == o.v }
}

extend Obj impl Copyable {
    fn copy(const self) -> Obj { return Obj(self.v) }
}

fn keep_third(x: *const u64) -> bool { return *x % 3 == 0 }

fn test_iteration_views() {
    var s: {u64}
    var back_empty = iter(s.items().iter()).rev().fold<string>("", cat_item)
    ck(xs_loop(s) == "" && back_empty == "", "empty: every view is empty")
    s.insert(7)
    ck(xs_loop(s) == "7 " && iter(s.items().iter()).rev().fold<string>("", cat_item) == "7 ", "one element")
    var t: {u64} = {9, 3, 6, 1, 4}
    ck(xs_loop(t) == "9 3 6 1 4 ", "forward")
    ck(iter(t.items().iter()).rev().fold<string>("", cat_item) == "4 1 6 3 9 ", "backward by iterator")
    var by_index = ""
    var i = t.items().size()
    while i > 0 {
        i -= 1
        by_index += f"{t.items()[i]} "
    }
    ck(by_index == "4 1 6 3 9 ", "backward by index")
    var pos = iter(t.items().iter()).enumerate().fold<u64>(0, weigh)
    ck(pos == 0 * 9 + 1 * 3 + 2 * 6 + 3 * 1 + 4 * 4, "enumerate: position times element")
}

fn weigh(acc: u64, p: (usize, *const u64)) -> u64 { return acc + (p.0 as u64) * *p.1 }

fn xs_loop(const s: {u64}) -> string {
    var a = ""
    for x in s { a += f"{x} " }
    return a
}

fn test_positional_reads() {
    var s: {u64}
    ck(!s.items().get(0)? && !s.items().first()? && !s.items().last()? && s.items().size() == 0, "empty: positional reads")
    s = {4, 9, 2, 7}
    ck(s.items()[0] == 4 && s.items()[3] == 7, "both ends by index")
    var g? = s.items().get(2)
    ck(g? && *g == 2 && !s.items().get(4)? && !s.items().get(99)?, "get(i): inside, at the end, past the end")
    var a? = s.items().at(-1)
    var b? = s.items().at(-4)
    ck(a? && *a == 7 && b? && *b == 4 && !s.items().at(-5)?, "at(-i) counts from the end")
    var f? = s.first()
    var l? = s.last()
    var sf? = s.items().first()
    var sl? = s.items().last()
    ck(f? && l? && sf? && sl? && f == sf && l == sl, "first and last are the slice's first and last, the same elements")
    var mid = s.items()[1..3]
    var tail = s.items()[2..]
    var head = s.items()[..2]
    ck(mid.size() == 2 && mid[0] == 9 && mid[1] == 2, "a range of positions")
    ck(tail.size() == 2 && tail[0] == 2 && head.size() == 2 && head[1] == 9, "tail and head")
    var at_of_seven? = s.items().index_of(7)
    ck(at_of_seven? && at_of_seven == 3, "the position of an element: index_of on the slice")
    s.swap_remove(4)
    ck(s.items().index_of(7)? && s.items().index_of(7) == 0 && !s.items().index_of(4)?, "after swap_remove the last element sits at the removed one's position")
    s.shift_remove(9)
    ck(s.items().index_of(2) == 1 && s.items().index_of(7) == 0, "after shift_remove the later elements are one lower")
    s.insert(100)
    ck(s.items().index_of(100) == s.size() - 1, "a new element lands at the last position")
}

fn test_index_matches_after_each_operation() {
    var s: {u64}
    ck(consistent(s), "empty")
    var good = true
    for var i: u64 = 0; i < 300; i += 1 {
        s.insert(i * 7919 % 523)
        if !consistent(s) { good = false; break }
    }
    ck(good, "after each of 300 inserts through four growths")
    for var i: u64 = 0; i < 100; i += 1 {
        s.swap_remove(i * 7919 % 523)
        if !consistent(s) { good = false; break }
    }
    ck(good, "after each swap_remove")
    for var i: u64 = 100; i < 200; i += 1 {
        s.shift_remove(i * 7919 % 523)
        if !consistent(s) { good = false; break }
    }
    ck(good, "after each shift_remove")
    for var i: u64 = 200; i < 230; i += 1 {
        var t? = s.take(i * 7919 % 523)
        if !consistent(s) { good = false; break }
    }
    ck(good, "after each take")
    for var i: u64 = 0; i < 30; i += 1 {
        s.pop()
        if !consistent(s) { good = false; break }
    }
    ck(good, "after each pop")
    s.retain(keep_third)
    ck(consistent(s), "after retain")
    var o: {u64}
    for var i: u64 = 0; i < 150; i += 1 { o.insert(i * 3 + 1) }
    s |= o
    ck(consistent(s), "after |=")
    s ^= o
    ck(consistent(s), "after ^=")
    s &= o
    ck(consistent(s), "after &=")
    s |= o
    s -= o
    ck(consistent(s), "after -=")
    var c = o.copy()
    ck(consistent(c), "a copy")
    o.clear()
    ck(consistent(o), "after clear")
}

fn test_growth_orders() {
    var s: {u64}
    var model: [u64]
    var good = true
    var checked: u64 = 0
    for var i: u64 = 0; i < 200000; i += 1 {
        var k = key_at(i)
        s.insert(k)
        model.push(k)
        if (i & (i + 1)) == 0 || (i & (i - 1)) == 0 {
            if !same(s, model) { good = false; break }
            checked += 1
        }
    }
    ck(good && checked > 30, "growth to 200000 elements: whole-set order at every table size")
    ck(same(s, model) && consistent(s), "growth: final order and index")
    var found = true
    for var i: u64 = 0; i < 200000; i += 997 { if !s.contains(key_at(i)) { found = false } }
    ck(found, "growth: lookups after the last rebuild")
}

fn test_reserve_and_shrink() {
    var s: {u64}
    var model: [u64]
    for var i: u64 = 0; i < 1000; i += 1 {
        s.insert(key_at(i))
        model.push(key_at(i))
    }
    s.reserve(100000)
    ck(same(s, model), "reserve: order kept")
    for var i: u64 = 1000; i < 1500; i += 1 {
        s.insert(key_at(i))
        model.push(key_at(i))
    }
    s.shrink_to_fit()
    ck(same(s, model), "shrink_to_fit: order kept")
    for var i: u64 = 0; i < 1400; i += 1 {
        var k = model.remove(0)
        s.shift_remove(k)
    }
    s.shrink_to_fit()
    ck(same(s, model) && s.size() == 100, "shrink_to_fit after removals: the 100 left keep their order")
    var w = {u64}::with_capacity(5000)
    var wm: [u64]
    for var i: u64 = 0; i < 5000; i += 1 {
        w.insert(key_at(i))
        wm.push(key_at(i))
    }
    ck(same(w, wm), "with_capacity: insertion order")
    var e: {u64}
    e.reserve(10)
    e.shrink_to_fit()
    e.insert(3)
    e.insert(1)
    ck(e.items()[0] == 3 && e.items()[1] == 1, "reserve and shrink on an empty set, then inserts")
}

fn test_copy_order() {
    var s: {u64}
    var model: [u64]
    for var i: u64 = 0; i < 3000; i += 1 {
        s.insert(key_at(i))
        model.push(key_at(i))
    }
    for var i: u64 = 0; i < 3000; i += 7 {
        var k = key_at(i)
        var at? = model.index_of(k)
        if at? {
            var pos: usize = at
            if i % 2 == 0 { model.swap_remove(pos); s.swap_remove(k) } else { model.remove(pos); s.shift_remove(k) }
        }
    }
    var c = s.copy()
    ck(same(c, model) && same(s, model) && consistent(c), "copy after removals: same order and positions, original untouched")
    c.insert(7)
    s.swap_remove(model[1])
    ck(c.size() == model.size() + 1 && c.items()[c.size() - 1] == 7, "copy: an insert appends to the copy only")
    ck(s.size() == model.size() - 1 && c.contains(model[1]) && !s.contains(model[1]), "copy: a removal in one is not seen in the other")
    var cc = c.copy()
    ck(cc.size() == c.size() && cc.items()[cc.size() - 1] == 7 && cc == c, "copy of a copy")
    for var i: u64 = 5000; i < 9000; i += 1 {
        c.insert(key_at(i))
        s.insert(key_at(i) + 1)
    }
    var good = true
    var base = model.size()
    for var i: u64 = 0; i < 4000; i += 1 {
        if c.items()[base + 1 + i as usize] != key_at(5000 + i) { good = false }
        if s.items()[base - 1 + i as usize] != key_at(5000 + i) + 1 { good = false }
    }
    ck(good, "copy: grown apart, each keeps its own order")
    var e: {u64}
    var ec = e.copy()
    ck(ec.size() == 0 && !ec.first()? && ec == e, "copy of an empty set")
    ec.insert(2)
    ec.insert(1)
    ck(ec.items()[0] == 2 && consistent(ec), "an empty set's copy takes inserts in order")
    var csize = c.size()
    var clast = c.items()[csize - 1]
    var b = c
    ck(b.size() == csize && b.items()[csize - 1] == clast && consistent(b), "a moved set keeps its order and index")
    var moved = make_set(600)
    var mm: [u64]
    for var i: u64 = 0; i < 600; i += 1 { mm.push(key_at(i)) }
    ck(same(moved, mm), "a set returned from a function keeps its order")
}

fn make_set(n: u64) -> {u64} {
    var s: {u64}
    for var i: u64 = 0; i < n; i += 1 { s.insert(key_at(i)) }
    return s
}

fn test_strings_and_counted() {
    var s: {string}
    for var i: u64 = 0; i < 400; i += 1 { s.insert(f"key-{i * 37 % 401}") }
    var c = s.copy()
    var good = c.size() == s.size()
    var i: u64 = 0
    for const *x in s {
        if *x != c.items()[i as usize] || *x != f"key-{i * 37 % 401}" { good = false }
        i += 1
    }
    ck(good && i == 400, "strings: copy keeps order, elements are deep")
    s.shift_remove("key-0")
    ck(c.contains("key-0") && c.size() == 400 && s.size() == 399, "strings: the copy keeps what the original lost")
    live = 0
    errors = 0
    {
        var o: {Obj}
        for var j: u64 = 0; j < 50; j += 1 { o.insert(Obj(j * 13 % 50)) }
        var oc = o.copy()
        ck(live == 100 && oc.items()[7].v == o.items()[7].v, "counted: a copy makes one object per element")
        o.swap_remove(Obj(0))
        ck(oc.size() == 50 && oc.items()[0].v == 0 && o.items()[0].v == o.items()[0].v && live == 99, "counted: the copy is independent")
    }
    ck(live == 0 && errors == 0, "counted: nothing leaked, nothing destroyed twice")
}

// How an element hashes, chosen per run: 0 writes v % 16, 1 writes nothing,
// 2 writes v. Equality is by v.
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

fn same_h(const s: {HKey}, const model: [u64]) -> bool {
    if s.size() != model.size() { return false }
    var i: usize = 0
    for const *x in s {
        if x->v != model[i] || s.items()[i].v != x->v { return false }
        i += 1
    }
    return true
}

fn keep_h(x: *const HKey) -> bool { return x->v % 3 != 0 }

fn test_collision_order() {
    for var m_i: u64 = 0; m_i < 3; m_i += 1 {
        mode = m_i
        var s: {HKey}
        var model: [u64]
        for var i: u64 = 0; i < 1500; i += 1 {
            var k = i * 2654435761 % 100003
            s.insert(HKey { v: k })
            if !model.contains(k) { model.push(k) }
        }
        ck(same_h(s, model), f"mode {m_i}: insertion order under collision")
        for var i: u64 = 0; i < 400; i += 1 {
            var pos = (i * 7) as usize % model.size()
            var gone = model.swap_remove(pos)
            s.swap_remove(HKey { v: gone })
            pos = (i * 11) as usize % model.size()
            gone = model.remove(pos)
            s.shift_remove(HKey { v: gone })
        }
        ck(same_h(s, model), f"mode {m_i}: both removals under collision match the vector")
        var p? = s.pop()
        var q? = model.pop()
        ck(p? && q? && p.v == q, f"mode {m_i}: pop under collision")
        s.retain(keep_h)
        var kept: [u64]
        for x in model { if x % 3 != 0 { kept.push(x) } }
        ck(same_h(s, kept), f"mode {m_i}: retain under collision")
        var found = true
        for x in kept { if !s.contains(HKey { v: x }) { found = false } }
        ck(found, f"mode {m_i}: every kept element found")
        var c = s.copy()
        ck(same_h(c, kept) && c == s, f"mode {m_i}: copy under collision")
        var other: {HKey}
        var all = [u64]::from_slice(kept)
        for var i: u64 = 0; i < 300; i += 1 {
            other.insert(HKey { v: i * 3 + 1 })
            if !kept.contains(i * 3 + 1) { all.push(i * 3 + 1) }
        }
        s |= other
        ck(same_h(s, all), f"mode {m_i}: |= under collision")
        s.clear()
        s.insert(HKey { v: 9 })
        s.insert(HKey { v: 1 })
        ck(s.size() == 2 && s.items()[0].v == 9, f"mode {m_i}: clear then reuse")
    }
}

fn main() -> i32 {
    test_iteration_views()
    test_positional_reads()
    test_index_matches_after_each_operation()
    test_growth_orders()
    test_reserve_and_shrink()
    test_copy_order()
    test_strings_and_counted()
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
