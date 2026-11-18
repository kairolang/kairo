// Positions in a HashMap<K, V>. The map's one positional view is the
// entries() slice: entry i is entries()[i], get(i) and at(i) of that slice
// answer null past the ends, and the slice starts and ends where first()
// and last() do. The index of a key is found by scanning that slice. After
// every kind of insert and removal the hash index and the entry array agree:
// get_entry(k) of the key at position i is the address of entries()[i].
//
// API gaps (indexmap members with no Kairo counterpart, so nothing is
// ported for them): get_index_of / get_full / get_index_mut as lookups by
// key to a position or by position to a key (only the slice read exists);
// swap_remove_index / shift_remove_index; swap_indices; move_index;
// shift_insert and insert_before / insert_full (an insert always appends);
// replace_index; sort_keys / sort_by / sort_unstable_by / sorted_by and
// their cached-key forms; binary_search_by / partition_point on the map;
// reverse; truncate; split_off; drain with a range; get_range; the
// is_sorted family.
//
// Cases from indexmap src/map/tests.rs (insert_order, get_index_entry, get_index_mut2, last_mut, first_mut, get_range)
// Cases from indexmap tests/quick.rs (indexing, insertion_order)

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

fn from_keys(const keys: [u64]) -> {u64: u64} {
    var m: {u64: u64}
    for x in keys { m.insert(x, x * 10) }
    return m
}

fn show(const v: [u64]) -> string {
    var a = ""
    for x in v { a += f"{x} " }
    return a
}

fn ks(const m: {u64: u64}) -> string {
    var a = ""
    for e in m.entries() { a += f"{e.key} " }
    return a
}

/// The position of `k`, found by scanning the entries; -1 when absent.
fn position(const m: {u64: u64}, k: u64) -> isize {
    for var i: usize = 0; i < m.entries().size(); i += 1 {
        if m.entries()[i].key == k { return i as isize }
    }
    return -1
}

/// The hash index and the entry array agree for every entry: the entry a key
/// is found by is the entry stored at that key's position, and its value is
/// the value stored there.
fn consistent(const m: {u64: u64}) -> bool {
    var n = m.entries().size()
    if n != m.size() { return false }
    for var i: usize = 0; i < n; i += 1 {
        var en? = m.get_entry(m.entries()[i].key)
        if !en? { return false }
        if en != &m.entries()[i] { return false }
        var *p? = m.get(m.entries()[i].key)
        if !p? || *p != m.entries()[i].value { return false }
    }
    return true
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

fn keep_third(k: *const u64, v: *u64) -> bool { return *k % 3 == 0 }
fn add(a: u64, b: u64) -> u64 { return a + b }

fn test_entries_slice_bounds() {
    var m: {u64: u64}
    ck(m.entries().size() == 0 && !m.entries().get(0)? && !m.entries().first()? && !m.entries().last()?, "empty: the entries slice is empty")
    m.insert(8, 80)
    ck(m.entries().size() == 1 && m.entries()[0].key == 8 && m.entries()[0].value == 80, "one entry: entries()[0]")
    var f? = m.entries().first()
    var l? = m.entries().last()
    ck(f? && l? && f->key == 8 && l->key == 8, "one entry: the slice's first and last")
    m = from_keys([4, 9, 2, 7])
    ck(m.entries().size() == 4 && m.entries()[0].key == 4 && m.entries()[3].key == 7, "four entries: both ends by index")
    var g? = m.entries().get(2)
    ck(g? && g->key == 2, "get(i) inside")
    ck(!m.entries().get(4)? && !m.entries().get(1000)?, "get(i) at and past the end is null")
    var a? = m.entries().at(-1)
    var b? = m.entries().at(-4)
    ck(a? && a->key == 7 && b? && b->key == 4 && !m.entries().at(-5)?, "at(-i) counts from the end")
    f = m.entries().first()
    l = m.entries().last()
    var mf? = m.first()
    var ml? = m.last()
    ck(f? && l? && mf? && ml? && f == mf && l == ml, "the slice's first and last are the map's first and last, the same entries")
    var part = m.entries()[1..3]
    ck(part.size() == 2 && part[0].key == 9 && part[1].key == 2, "a range of positions")
    var tail = m.entries()[2..]
    ck(tail.size() == 2 && tail[0].key == 2 && tail[1].key == 7, "positions from 2 on")
    var head = m.entries()[..2]
    ck(head.size() == 2 && head[0].key == 4 && head[1].key == 9, "positions before 2")
}

fn test_position_of_key() {
    var keys: [u64] = [0, 4, 2, 12, 8, 7, 11, 5, 3, 17, 19, 22, 23]
    var m = from_keys(keys)
    var good = true
    for var i: usize = 0; i < keys.size(); i += 1 {
        if position(m, keys[i]) != i as isize { good = false }
    }
    ck(good && position(m, 99) == -1, "position of a key is its place in the insertion sequence")
    m.swap_remove(4)
    ck(position(m, 23) == 1 && position(m, 4) == -1 && position(m, 2) == 2, "after swap_remove the last key sits at the removed key's position")
    m.shift_remove(0)
    ck(position(m, 23) == 0 && position(m, 2) == 1 && position(m, 22) == 10, "after shift_remove every later key is one position lower")
    m.insert(100, 1)
    ck(position(m, 100) == m.size() as isize - 1, "a new key lands at the last position")
    m.insert(2, 77)
    ck(position(m, 2) == 1, "a replaced key keeps its position")
}

fn test_index_matches_after_each_operation() {
    var m: {u64: u64}
    ck(consistent(m), "empty")
    for var i: u64 = 0; i < 300; i += 1 {
        m.insert(i * 7919 % 523, i)
        if !consistent(m) { ck(false, f"consistent after insert {i}"); break }
    }
    ck(consistent(m), "after 300 inserts through four growths")
    var good = true
    for var i: u64 = 0; i < 100; i += 1 {
        m.swap_remove(i * 7919 % 523)
        if !consistent(m) { good = false; break }
    }
    ck(good, "after each swap_remove")
    for var i: u64 = 100; i < 200; i += 1 {
        m.shift_remove(i * 7919 % 523)
        if !consistent(m) { good = false; break }
    }
    ck(good, "after each shift_remove")
    for var i: u64 = 0; i < 30; i += 1 {
        m.pop()
        if !consistent(m) { good = false; break }
    }
    ck(good, "after each pop")
    m.retain(keep_third)
    ck(consistent(m), "after retain")
    var o: {u64: u64}
    for var i: u64 = 0; i < 150; i += 1 { o.insert(i * 3 + 1, i) }
    m.merge(o, add)
    ck(consistent(m), "after merge")
    m[100000] += 1
    m[100001] = 2
    ck(consistent(m), "after the place form and the setter")
    var c = m.copy()
    ck(consistent(c) && ks(c) == ks(m), "a copy: index and entries agree, same positions")
    m.clear()
    ck(consistent(m), "after clear")
    m.insert(1, 1)
    ck(consistent(m) && ks(m) == "1 ", "after clear and an insert")
}

fn test_positions_in_moved_and_copied() {
    var a = from_keys([9, 8, 7, 6, 5, 4, 3, 2, 1])
    var b = a.copy()
    a.swap_remove(9)
    ck(ks(b) == "9 8 7 6 5 4 3 2 1 " && ks(a) == "1 8 7 6 5 4 3 2 ", "a copy keeps the positions the original had, and does not share them")
    var c = b
    ck(ks(c) == "9 8 7 6 5 4 3 2 1 " && consistent(c), "a moved map keeps its positions")
}

fn test_strings_and_counted() {
    var m: {string: u64}
    m.insert("b".copy(), 1)
    m.insert("a".copy(), 2)
    m.insert("c".copy(), 3)
    ck(m.entries()[0].key == "b" && m.entries()[2].key == "c" && m.entries().size() == 3, "strings: positional read")
    m.shift_remove("b")
    ck(m.entries()[0].key == "a" && m.entries().size() == 2, "strings: after shift_remove")
    live = 0
    errors = 0
    {
        var o: {u64: Obj}
        for var i: u64 = 0; i < 10; i += 1 { o.insert(i, Obj(i * i)) }
        ck(o.entries()[3].value.v == 9 && o.entries()[9].value.v == 81, "counted: positional read")
        o.swap_remove(3)
        ck(o.entries()[3].key == 9 && o.entries()[3].value.v == 81 && live == 9, "counted: the last entry moved into position 3")
        o.shift_remove(0)
        ck(o.entries()[0].key == 1 && o.entries().size() == 8 && live == 8, "counted: shift_remove")
    }
    ck(live == 0 && errors == 0, "counted: nothing leaked, nothing destroyed twice")
}

fn main() -> i32 {
    test_entries_slice_bounds()
    test_position_of_key()
    test_index_matches_after_each_operation()
    test_positions_in_moved_and_copied()
    test_strings_and_counted()
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
