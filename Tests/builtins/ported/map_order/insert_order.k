// Where an entry lands in a HashMap<K, V> after every way of adding one: a
// new key goes to the end; an existing key keeps its place and its stored
// key whichever call finds it (insert, the setter, the place form,
// try_insert, get_or_insert, get_or_insert_with, get_or_default, merge,
// extend_from, a literal with a repeated key); a key added again after a
// removal goes to the end. first() and last() follow the ends.
//
// differs from C++ and Rust: iteration order is defined (hash_map.k, the doc
// comment on HashMap; "a replaced entry keeps its place and the key already
// stored" on insert; "a repeated key keeps its first place and takes its
// last value" for a literal).
//
// Cases from indexmap src/map/tests.rs (insert, insert_2, insert_order, insert_full, extend, from_entries, entry, entry_or_default)
// Cases from indexmap tests/quick.rs (insertion_order, operations_i8 with the Add and AddEntry operations)
// Cases from indexmap src/set/tests.rs (insert_order, replace_order)

import std::iter::*
import std::io

var checks: u64 = 0
var failures: u64 = 0
var live: i64 = 0
var errors: u64 = 0
var made_runs: u64 = 0

fn ck(cond: bool, const what: string) {
    checks += 1
    if !cond {
        failures += 1
        io::println(f"FAIL {what}")
    }
}

/// The keys in order, read through keys(), the for loop and entries(); the
/// text says so when they disagree.
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

/// The pairs in order.
fn kv(const m: {u64: u64}) -> string {
    var a = ""
    for (k, v) in m { a += f"{k}={v} " }
    return a
}

/// The last-found entry ends: first() and last() against the entries.
fn ends(const m: {u64: u64}) -> bool {
    if m.size() == 0 { return !m.first()? && !m.last()? }
    var f? = m.first()
    var l? = m.last()
    return f? && l? && f->key == m.entries()[0].key && l->key == m.entries()[m.size() - 1].key
}

struct TKey {
    pub var id: u64
    pub var tag: u64
}

extend TKey impl Hash {
    fn hash(const self, @inout h: Hasher) { h.write_u64(self.id) }
    fn op == (const self, const o: TKey) -> bool { return self.id == o.id }
}

extend TKey impl Copyable {
    fn copy(const self) -> TKey { return TKey { id: self.id, tag: self.tag } }
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

fn add(a: u64, b: u64) -> u64 { return a + b }
fn second(a: u64, b: u64) -> u64 { return b }
fn tenfold() -> u64 {
    made_runs += 1
    return 1000
}

fn test_insert_new_keys_go_last() {
    var insert: [u64] = [0, 4, 2, 12, 8, 7, 11, 5, 3, 17, 19, 22, 23]
    var m: {u64: u64}
    ck(ks(m) == "" && ends(m), "empty map: no order, no ends")
    var want = ""
    for var i: usize = 0; i < insert.size(); i += 1 {
        var old? = m.insert(insert[i], insert[i] * 2)
        want += f"{insert[i]} "
        ck(!old?, "insert of a new key returns null")
        ck(ends(m), "first and last follow every insert")
    }
    ck(ks(m) == want, "insert: keys in insertion order")
    ck(m.size() == insert.size(), "insert: size")
    var agree = true
    var j: usize = 0
    for k in m.keys() {
        if *k != insert[j] || m.entries()[j].key != *k { agree = false }
        j += 1
    }
    ck(agree && j == insert.size(), "insert: the entry at position i is the i-th key")
    var f? = m.first()
    var l? = m.last()
    ck(f? && f->key == 0 && f->value == 0 && l? && l->key == 23 && l->value == 46, "insert: first and last are the first and last keys")
}

fn test_insert_existing_keeps_place() {
    var m: {u64: u64}
    for var i: u64 = 1; i <= 6; i += 1 { m.insert(i, i) }
    var old? = m.insert(3, 300)
    ck(old? && old == 3, "insert of a present key returns the replaced value")
    ck(ks(m) == "1 2 3 4 5 6 " && m[3] == 300, "insert replace: place kept in the middle")
    old = m.insert(1, 100)
    ck(old? && old == 1 && ks(m) == "1 2 3 4 5 6 " && m[1] == 100, "insert replace: first stays first")
    old = m.insert(6, 600)
    ck(old? && old == 6 && ks(m) == "1 2 3 4 5 6 " && m[6] == 600, "insert replace: last stays last")
    ck(kv(m) == "1=100 2=2 3=300 4=4 5=5 6=600 ", "insert replace: values")
    ck(ends(m) && m.size() == 6, "insert replace: size and ends")
    // A map of one entry replaced is still one entry.
    var one: {u64: u64} = {9: 1}
    old = one.insert(9, 2)
    ck(old? && old == 1 && ks(one) == "9 " && one[9] == 2, "insert replace: one entry")
}

fn test_insert_existing_keeps_stored_key() {
    var m: {TKey: u64}
    m.insert(TKey { id: 1, tag: 10 }, 1)
    m.insert(TKey { id: 2, tag: 20 }, 2)
    m.insert(TKey { id: 1, tag: 11 }, 3)
    ck(m.size() == 2 && m.entries()[0].key.id == 1 && m.entries()[0].value == 3, "stored key: the replaced entry keeps its place")
    ck(m.entries()[0].key.tag == 10, "stored key: insert keeps the key already stored")
    var s: {TKey: u64}
    s[TKey { id: 5, tag: 50 }] = 1
    s[TKey { id: 5, tag: 51 }] = 2
    ck(s.size() == 1 && s.entries()[0].key.tag == 50 && s.entries()[0].value == 2, "stored key: the setter keeps the key already stored")
    s[TKey { id: 5, tag: 52 }] += 5
    ck(s.size() == 1 && s.entries()[0].key.tag == 50 && s.entries()[0].value == 7, "stored key: the place form keeps the key already stored")
    var t: {TKey: u64}
    t.insert(TKey { id: 7, tag: 70 }, 1)
    var back? = t.try_insert(TKey { id: 7, tag: 71 }, 2)
    ck(back? && back == 2 && t.entries()[0].key.tag == 70 && t.entries()[0].value == 1, "stored key: try_insert keeps the entry as it is")
}

fn test_setter_order() {
    var m: {u64: u64}
    m[30] = 1
    m[10] = 2
    m[20] = 3
    ck(ks(m) == "30 10 20 ", "setter: new keys append")
    m[10] = 22
    m[30] = 11
    m[20] = 33
    ck(ks(m) == "30 10 20 " && kv(m) == "30=11 10=22 20=33 ", "setter: present keys keep their place")
    m[40] = 4
    ck(ks(m) == "30 10 20 40 " && ends(m), "setter: a new key after replaces appends")
    // The setter on strings.
    var s: {string: u64}
    s["b"] = 1
    s["a"] = 2
    s["b"] = 3
    s["c"] = 4
    var order = ""
    for (const *k, const *v) in s { order += f"{*k}{*v} " }
    ck(order == "b3 a2 c4 ", "setter with string keys: order and values")
}

fn test_place_form_order() {
    var m: {u64: u64}
    m[7] += 1
    m[3] += 1
    m[7] += 1
    m[5] += 1
    m[3] += 5
    ck(ks(m) == "7 3 5 " && kv(m) == "7=2 3=6 5=1 ", "place form: order of first use, values accumulate")
    m[7] -= 2
    ck(ks(m) == "7 3 5 " && m[7] == 0, "place form: a hit that changes the value keeps the place")
    var c: {string: u64}
    c["z"] += 1
    c["y"] += 1
    c["z"] += 1
    var order = ""
    for (const *k, const *v) in c { order += f"{*k}{*v} " }
    ck(order == "z2 y1 ", "place form with string keys")
}

fn test_try_insert_order() {
    var m: {u64: u64}
    var r? = m.try_insert(5, 50)
    r = m.try_insert(3, 30)
    ck(!r? && ks(m) == "5 3 ", "try_insert: vacant keys append")
    r = m.try_insert(5, 51)
    ck(r? && r == 51 && ks(m) == "5 3 " && m[5] == 50, "try_insert: an occupied key keeps place and value")
    r = m.try_insert(4, 40)
    ck(!r? && ks(m) == "5 3 4 " && ends(m), "try_insert: a vacant key appends after refusals")
}

fn test_get_or_insert_order() {
    var m: {u64: u64}
    var *p = m.get_or_insert(8, 80)
    ck(*p == 80 && ks(m) == "8 ", "get_or_insert: a miss appends")
    p = m.get_or_insert(2, 20)
    ck(*p == 20 && ks(m) == "8 2 ", "get_or_insert: a second miss appends")
    p = m.get_or_insert(8, 99)
    ck(*p == 80 && ks(m) == "8 2 ", "get_or_insert: a hit keeps place and value")
    *p = 81
    ck(kv(m) == "8=81 2=20 ", "get_or_insert: the pointer writes the entry in place")

    made_runs = 0
    var *q = m.get_or_insert_with(3, tenfold)
    ck(*q == 1000 && made_runs == 1 && ks(m) == "8 2 3 ", "get_or_insert_with: a miss runs make and appends")
    q = m.get_or_insert_with(8, tenfold)
    ck(*q == 81 && made_runs == 1 && ks(m) == "8 2 3 ", "get_or_insert_with: a hit does not run make")

    var d: {u64: u64}
    var *z = d.get_or_default(9)
    ck(*z == 0 && ks(d) == "9 ", "get_or_default: a miss appends a default")
    *z = 5
    z = d.get_or_default(1)
    z = d.get_or_default(9)
    ck(*z == 5 && ks(d) == "9 1 ", "get_or_default: a hit keeps the place")
}

fn test_merge_order() {
    var a: {u64: u64} = {1: 10, 2: 20, 3: 30}
    var b: {u64: u64} = {9: 90, 3: 3, 0: 5, 1: 1}
    a.merge(b, add)
    ck(ks(a) == "1 2 3 9 0 " && kv(a) == "1=11 2=20 3=33 9=90 0=5 ", "merge: shared keys keep place, other's new keys follow in other's order")

    var c: {u64: u64} = {4: 4}
    var e: {u64: u64}
    c.merge(e, add)
    ck(ks(c) == "4 ", "merge: an empty other changes nothing")

    var f: {u64: u64}
    var g: {u64: u64} = {7: 1, 5: 2, 6: 3}
    f.merge(g, add)
    ck(ks(f) == "7 5 6 " && kv(f) == "7=1 5=2 6=3 ", "merge into an empty map takes other's order")

    var h: {u64: u64} = {1: 1, 2: 2}
    var i: {u64: u64} = {2: 5, 1: 7}
    h.merge(i, second)
    ck(ks(h) == "1 2 " && kv(h) == "1=7 2=5 ", "merge: resolve picks the value, order stays mine")

    var big: {u64: u64}
    var other: {u64: u64}
    for var n: u64 = 0; n < 500; n += 1 { big.insert(n * 2, n) }
    for var n: u64 = 0; n < 500; n += 1 { other.insert(n * 3, n) }
    big.merge(other, add)
    var ok = true
    var idx: usize = 0
    for k in big.keys() {
        if idx < 500 {
            if *k != (idx as u64) * 2 { ok = false }
        } else if *k % 3 != 0 || (*k % 2 == 0 && *k <= 998) {
            ok = false
        }
        idx += 1
    }
    ck(ok && idx == big.size() && idx == 500 + 500 - 167, "merge: 500 and 500 entries, the the multiples of six below 1000 are merged, not repeated")
    // The odd multiples of three arrive in other's order.
    var prev: u64 = 0
    var increasing = true
    var pos: usize = 0
    for k in big.keys() {
        if pos >= 500 {
            if *k < prev { increasing = false }
            prev = *k
        }
        pos += 1
    }
    ck(increasing, "merge: appended keys keep other's order")
}

fn test_extend_from_order() {
    var m: {u64: u64} = {5: 50}
    var items: [(u64, u64)] = [(7, 70), (5, 51), (6, 60), (7, 71), (4, 40)]
    m.extend_from(items)
    ck(ks(m) == "5 7 6 4 " && kv(m) == "5=51 7=71 6=60 4=40 ", "extend_from: new keys append, a repeat keeps its first place and takes its last value")
    var none: [(u64, u64)]
    m.extend_from(none)
    ck(ks(m) == "5 7 6 4 ", "extend_from: an empty slice changes nothing")
    var fresh = {u64: u64}::from_slice(items)
    ck(ks(fresh) == "7 5 6 4 " && kv(fresh) == "7=71 5=51 6=60 4=40 ", "from_slice: first place, last value")
    var from_empty = {u64: u64}::from_slice(none)
    ck(ks(from_empty) == "" && ends(from_empty), "from_slice: an empty slice")
}

fn test_literal_order() {
    var m: {u64: u64} = {3: 1, 1: 2, 3: 9, 2: 4, 1: 7}
    ck(ks(m) == "3 1 2 " && kv(m) == "3=9 1=7 2=4 ", "literal: a repeated key keeps its first place and takes its last value")
    var single: {u64: u64} = {8: 8}
    ck(ks(single) == "8 " && ends(single), "literal: one pair")
    var strs: {string: u64} = {"x": 1, "w": 2, "x": 3}
    var order = ""
    for (const *k, const *v) in strs { order += f"{*k}{*v} " }
    ck(order == "x3 w2 ", "literal with string keys: repeat keeps first place")
}

fn test_collect_order() {
    var pairs: [u64] = [4, 9, 4, 2, 9, 1]
    var m = iter(pairs.iter()).map(twin).collect<{u64: u64}>()
    ck(ks(m) == "4 9 2 1 " && kv(m) == "4=4 9=9 2=2 1=1 ", "collect: first place, new keys append")
    var s = iter(pairs.iter()).copied().collect<{u64}>()
    var order = ""
    for x in s { order += f"{x} " }
    ck(order == "4 9 2 1 ", "collect into a set: first place")
}

fn twin(x: *const u64) -> (u64, u64) { return (*x, *x) }

fn test_reinsert_after_removal() {
    var m: {u64: u64} = {1: 1, 2: 2, 3: 3, 4: 4, 5: 5}
    m.swap_remove(2)
    ck(ks(m) == "1 5 3 4 ", "swap_remove moves the last entry into the gap")
    m.insert(2, 22)
    ck(ks(m) == "1 5 3 4 2 ", "insert after swap_remove: the key goes to the end")
    m.shift_remove(1)
    ck(ks(m) == "5 3 4 2 ", "shift_remove closes the gap")
    m[1] = 11
    ck(ks(m) == "5 3 4 2 1 ", "setter after shift_remove: the key goes to the end")
    m.pop()
    m.insert(1, 12)
    ck(ks(m) == "5 3 4 2 1 " && m[1] == 12, "insert after pop: the popped key comes back last")
    m.clear()
    ck(ks(m) == "" && ends(m), "clear: no entries, no ends")
    m[9] = 1
    m[8] = 2
    m[9] = 3
    ck(ks(m) == "9 8 " && kv(m) == "9=3 8=2 ", "clear then reuse: order starts again")
}

fn test_strings_order() {
    var m: {string: string}
    var names: [string] = ["delta".copy(), "alpha".copy(), "charlie".copy(), "bravo".copy()]
    for var i: usize = 0; i < names.size(); i += 1 { m.insert(names[i].copy(), f"v{i}") }
    var order = ""
    for k in m.keys() { order += f"{*k} " }
    ck(order == "delta alpha charlie bravo ", "strings: keys in insertion order")
    var old? = m.insert("alpha".copy(), "new".copy())
    ck(old? && old == "v1", "strings: insert returns the old value")
    order = ""
    for (const *k, const *v) in m { order += f"{*k}={*v} " }
    ck(order == "delta=v0 alpha=new charlie=v2 bravo=v3 ", "strings: replaced value, place kept")
    var f? = m.first()
    var l? = m.last()
    ck(f? && f->key == "delta" && l? && l->key == "bravo", "strings: first and last")
}

fn test_counted_order() {
    live = 0
    errors = 0
    {
        var m: {u64: Obj}
        for var i: u64 = 0; i < 20; i += 1 { m.insert(i * 7 % 20, Obj(i)) }
        ck(live == 20, "counted: one live object per entry")
        var old? = m.insert(0, Obj(500))
        ck(old? && old.v == 0 && live == 21, "counted: insert hands the replaced value back")
        old = null
        ck(live == 20, "counted: the handed-back value dies when dropped")
        var back? = m.try_insert(7, Obj(600))
        ck(back? && back.v == 600 && live == 21, "counted: try_insert hands the new value back")
        back = null
        ck(live == 20, "counted: the refused value dies when dropped")
        var order = ""
        for const *e in m.entries() { order += f"{e->key}:{e->value.v} " }
        ck(order == "0:500 7:1 14:2 1:3 8:4 15:5 2:6 9:7 16:8 3:9 10:10 17:11 4:12 11:13 18:14 5:15 12:16 19:17 6:18 13:19 ", "counted: order and values")
        var other: {u64: Obj}
        other.insert(0, Obj(1))
        other.insert(77, Obj(2))
        m.merge(other, keep_second)
        ck(live == 21, "counted: merge consumes the other map, one object per entry")
        var lastp? = m.last()
        ck(m.size() == 21 && lastp? && lastp->key == 77 && m[0].v == 1, "counted: merge appends and resolves")
    }
    ck(live == 0 && errors == 0, "counted: nothing leaked, nothing destroyed twice")
}

fn keep_second(a: Obj, b: Obj) -> Obj { return b }

fn main() -> i32 {
    test_insert_new_keys_go_last()
    test_insert_existing_keeps_place()
    test_insert_existing_keeps_stored_key()
    test_setter_order()
    test_place_form_order()
    test_try_insert_order()
    test_get_or_insert_order()
    test_merge_order()
    test_extend_from_order()
    test_literal_order()
    test_collect_order()
    test_reinsert_after_removal()
    test_strings_order()
    test_counted_order()
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
