// The write members of HashMap<K, V> that add or replace: insert (which
// returns the replaced value), try_insert (the entry API's vacant case),
// the setter `m[k] = v`, the place form `m[k] += 1` that inserts a default,
// get_or_insert, get_or_insert_with, get_or_default, merge and extend_from.
// A replaced entry keeps its place and the key already stored; a new entry
// goes last.
//
// differs from C++: `insert` returns the old value (`V?`), not a pair of an
// iterator and a flag; `try_emplace` is `try_insert`, which hands the value
// back when the key exists (hash_map.k, the doc comment on try_insert).
//
// Cases from libc++ test/std/containers/unord/unord.map/unord.map.modifiers/
// Cases from libc++ test/std/containers/unord/unord.map/unord.map.elem/
// Cases from Rust library/std/src/collections/hash/map/tests.rs
// Cases from hashbrown src/map.rs tests (insert, entry, extend, overwrite)

import std::io

var checks: u64 = 0
var failures: u64 = 0
var live: i64 = 0
var errors: u64 = 0
var made: u64 = 0

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

struct Count {
    pub var n: u64
}

extend Count impl Default {
    static fn make_default() -> Count { return Count { n: 0 } }
}

fn seven() -> u64 {
    made += 1
    return 7
}

fn add(a: u64, b: u64) -> u64 { return a + b }

fn sum_obj(x: Obj, y: Obj) -> Obj { return Obj(x.v + y.v) }

fn keep_left(a: u64, b: u64) -> u64 { return a }

fn test_insert_returns_old_value() {
    var m: {u64: u64}
    var r? = m.insert(1, 10)
    ck(!r? && m.size() == 1, "insert: new key returns null")
    r = m.insert(1, 11)
    ck(r? && r == 10 && m.size() == 1 && m[1] == 11, "insert: present key returns the old value")
    r = m.insert(2, 20)
    ck(!r? && m.size() == 2, "insert: a second key")
    r = m.insert(1, 12)
    ck(r? && r == 11 && m[1] == 12, "insert: replaced twice")
    ck(m.entries()[0].key == 1 && m.entries()[1].key == 2, "insert: a replaced entry keeps its place")
}

fn test_insert_zero_values() {
    var m: {u64: u64}
    m.insert(0, 0)
    ck(m.size() == 1 && m[0] == 0 && m.contains(0), "insert: key 0, value 0")
    var r? = m.insert(0, 0)
    ck(r? && r == 0, "insert: an old value of 0 is still a value")
}

fn test_insert_many_order() {
    var m: {u64: u64}
    for var i: u64 = 0; i < 2000; i += 1 {
        m.insert((i * 7919) % 10007, i)
    }
    ck(m.size() == 2000, "insert: 2000 distinct keys through many growths")
    var bad: u64 = 0
    var i: u64 = 0
    for (k, v) in m {
        if k != (i * 7919) % 10007 || v != i { bad += 1 }
        i += 1
    }
    ck(bad == 0 && i == 2000, "insert: iteration is insertion order after growth")
    for var j: u64 = 0; j < 2000; j += 1 {
        var *p? = m.get((j * 7919) % 10007)
        if !p? || *p != j { bad += 1 }
    }
    ck(bad == 0, "insert: every key found with its value")
    var shown: u64 = 0
    for var j: u64 = 0; j < 2000; j += 1 {
        if m.insert((j * 7919) % 10007, j + 1) != null { shown += 1 }
    }
    ck(shown == 2000 && m.size() == 2000, "insert: overwriting every key keeps the size")
    ck(m.entries()[0].key == 0 && m.entries()[0].value == 1, "insert: overwrite keeps order")
}

fn test_try_insert() {
    var m: {u64: u64}
    var r? = m.try_insert(1, 10)
    ck(!r? && m[1] == 10, "try_insert: vacant key inserts and returns null")
    r = m.try_insert(1, 99)
    ck(r? && r == 99 && m[1] == 10 && m.size() == 1, "try_insert: occupied key hands the value back")
    r = m.try_insert(2, 20)
    ck(!r? && m.size() == 2 && m.entries()[1].key == 2, "try_insert: appends")
    var s: {string: string}
    var back? = s.try_insert("a".copy(), "x".copy())
    ck(!back?, "try_insert strings: vacant")
    back = s.try_insert("a".copy(), "y".copy())
    ck(back? && back == "y" && s["a"] == "x", "try_insert strings: occupied returns the new value")
}

fn test_setter() {
    var m: {u64: u64}
    m[3] = 30
    ck(m.size() == 1 && m[3] == 30, "setter inserts")
    m[3] = 31
    ck(m.size() == 1 && m[3] == 31, "setter replaces")
    m[4] = 40
    m[3] = 32
    ck(m.entries()[0].key == 3 && m.entries()[1].key == 4, "setter keeps the place of a replaced key")
    var s: {string: string}
    s["k"] = "v1"
    s["k"] = "v2"
    s["j"] = "w"
    ck(s.size() == 2 && s["k"] == "v2" && s["j"] == "w", "setter with string key and value")
    var k = "key".copy()
    s[k] = "z"
    ck(k == "key" && s["key"] == "z", "setter copies the key it is given")
    for var i: u64 = 0; i < 1000; i += 1 { m[i] = i * 2 }
    ck(m.size() == 1000 && m[999] == 1998 && m[3] == 6, "setter through growth")
}

fn test_place_form() {
    var m: {u64: u64}
    m[5] += 1
    ck(m.size() == 1 && m[5] == 1, "place form: a miss inserts the default then adds")
    m[5] += 1
    m[5] += 10
    ck(m.size() == 1 && m[5] == 12, "place form: a hit updates in place")
    m[6] -= 0
    ck(m.contains(6) && m[6] == 0, "place form: a miss with += 0 still inserts")
    var c: {string: Count}
    c["a"].n += 2
    c["a"].n += 3
    c["b"].n += 1
    ck(c.size() == 2 && c["a"].n == 5 && c["b"].n == 1, "place form: struct values, string keys")
    ck(c.entries()[0].key == "a" && c.entries()[1].key == "b", "place form: order of first use")
    var w: {u64: u64}
    for var i: u64 = 0; i < 3000; i += 1 { w[i % 97] += 1 }
    var bad: u64 = 0
    for (k, v) in w {
        var want: u64 = 3000 / 97
        if k < 3000 % 97 { want += 1 }
        if v != want { bad += 1 }
    }
    ck(w.size() == 97 && bad == 0, "place form: counting 3000 events over 97 keys")
    var sv: {u64: string}
    sv[1] += "ab"
    sv[1] += "cd"
    ck(sv[1] == "abcd", "place form: appending to a string value")
}

fn test_get_or_insert() {
    var m: {u64: u64}
    var *p = m.get_or_insert(1, 10)
    ck(*p == 10 && m.size() == 1, "get_or_insert: a miss inserts")
    *p = 11
    p = m.get_or_insert(1, 99)
    ck(*p == 11 && m.size() == 1, "get_or_insert: a hit keeps the stored value")
    p = m.get_or_insert_with(2, seven)
    ck(*p == 7 && made == 1 && m.size() == 2, "get_or_insert_with: a miss makes the value")
    p = m.get_or_insert_with(2, seven)
    ck(*p == 7 && made == 1, "get_or_insert_with: a hit makes nothing")
    var c: {u64: Count}
    var *d = c.get_or_default(4)
    d->n += 3
    d = c.get_or_default(4)
    ck(d->n == 3 && c.size() == 1, "get_or_default: miss then hit")
    var s: {string: string}
    var *sp = s.get_or_default("q".copy())
    ck(*sp == "" && s.contains("q"), "get_or_default: a default string")
    var o: {u64: Obj}
    var *ob = o.get_or_insert(1, Obj(5))
    ck(ob->v == 5 && live == 1, "get_or_insert: move-only value")
    ob = o.get_or_insert(1, Obj(6))
    ck(ob->v == 5 && live == 1, "get_or_insert: a hit destroys the value it was given")
}

fn test_merge() {
    var a: {u64: u64} = {1: 10, 2: 20}
    var b: {u64: u64} = {2: 5, 3: 30}
    a.merge(b, add)
    ck(a.size() == 3 && a[1] == 10 && a[2] == 25 && a[3] == 30, "merge: resolve on a common key, move the rest")
    ck(a.entries()[2].key == 3, "merge: new keys go last in the other map's order")
    var c: {u64: u64} = {1: 1}
    var e: {u64: u64}
    c.merge(e, add)
    ck(c.size() == 1 && c[1] == 1, "merge: an empty other changes nothing")
    var f: {u64: u64}
    var g: {u64: u64} = {8: 80, 9: 90}
    f.merge(g, add)
    ck(f.size() == 2 && f.entries()[0].key == 8, "merge into an empty map")
    var h: {u64: u64} = {1: 1, 2: 2}
    var i: {u64: u64} = {1: 9, 2: 9}
    h.merge(i, keep_left)
    ck(h[1] == 1 && h[2] == 2, "merge: the resolver chooses")
    var o: {u64: Obj}
    var p: {u64: Obj}
    for var j: u64 = 0; j < 10; j += 1 { o.insert(j, Obj(j)) }
    for var j: u64 = 5; j < 15; j += 1 { p.insert(j, Obj(j * 100)) }
    o.merge(p, sum_obj)
    ck(o.size() == 15 && o[7].v == 7 + 700 && o[12].v == 1200 && o[3].v == 3, "merge: move-only values")
}

fn test_extend_from() {
    var m: {u64: u64} = {1: 10}
    var items: [(u64, u64)] = [(1, 11), (2, 20), (3, 30), (2, 21)]
    m.extend_from(items)
    ck(m.size() == 3 && m[1] == 11 && m[2] == 21 && m[3] == 30, "extend_from: later pairs replace earlier values")
    ck(m.entries()[0].key == 1 && m.entries()[2].key == 3, "extend_from: order")
    var none: [(u64, u64)]
    m.extend_from(none)
    ck(m.size() == 3, "extend_from: empty slice")
    var big: [(u64, u64)]
    for var i: u64 = 0; i < 500; i += 1 { big.push((i, i)) }
    var n: {u64: u64}
    n.extend_from(big)
    ck(n.size() == 500 && n[499] == 499 && big.size() == 500, "extend_from: many, source kept")
}

fn test_counted() {
    {
        var m: {u64: Obj}
        for var i: u64 = 0; i < 100; i += 1 { m.insert(i, Obj(i)) }
        ck(live == 100, "counted: one object per entry")
        var old? = m.insert(5, Obj(500))
        ck(old? && old.v == 5 && live == 101, "counted: insert hands the replaced object out")
        old = null
        ck(live == 100 && m[5].v == 500, "counted: dropping the returned value destroys it")
        var back? = m.try_insert(6, Obj(600))
        ck(back? && back.v == 600 && live == 101 && m[6].v == 6, "counted: try_insert returns the new object")
        back = null
        ck(live == 100, "counted: after dropping it")
        m[7] = Obj(700)
        ck(live == 100 && m[7].v == 700, "counted: the setter destroys the replaced object")
        m[200] = Obj(2)
        ck(live == 101, "counted: the setter inserts")
    }
    ck(live == 0 && errors == 0, "insert: nothing leaked, nothing destroyed twice")
}

fn main() -> i32 {
    test_insert_returns_old_value()
    test_insert_zero_values()
    test_insert_many_order()
    test_try_insert()
    test_setter()
    test_place_form()
    test_get_or_insert()
    test_merge()
    test_extend_from()
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
