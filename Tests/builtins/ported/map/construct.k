// Construction, move, copy and the literal form of HashMap<K, V>, on empty,
// one-entry and many-entry maps, with integer, string and move-only counted
// elements. A map keeps insertion order; a literal with a repeated key keeps
// the first place and takes the last value (the doc comment on HashMap).
//
// Cases from libc++ test/std/containers/unord/unord.map/unord.map.cnstr/ and unord.map.swap/
// Cases from Rust library/std/src/collections/hash/map/tests.rs
// Cases from hashbrown src/map.rs tests (zero capacities, clone, from_iter)

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

/// Move-only, counts live objects, detects a double destroy and a read after a move.
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

class Seq {
    var i: u64
    var n: u64
    pub fn Seq(self, n: u64) {
        self.i = 0
        self.n = n
    }
}

extend Seq impl Iterator {
    type Item = (u64, u64)
    fn next(self) -> (u64, u64)? {
        if self.i == self.n { return null }
        var r = (self.i, self.i * 10)
        self.i += 1
        return r
    }
}

fn in_order(const m: {u64: u64}, n: u64) -> bool {
    var i: u64 = 0
    for (k, v) in m {
        if k != i || v != i * 10 { return false }
        i += 1
    }
    return i == n
}

fn test_default_is_empty() {
    var m: {u64: u64}
    ck(m.size() == 0 && m.is_empty(), "default: empty")
    ck(m.capacity() == 0, "default: no allocation")
    var d = HashMap<u64, u64>()
    ck(d.size() == 0 && d.capacity() == 0, "HashMap(): empty and no allocation")
    var e: {string: string}
    ck(e.is_empty() && e.capacity() == 0, "default string map")
    var dd = HashMap<u64, u64>::make_default()
    ck(dd.is_empty(), "make_default")
}

fn test_with_capacity() {
    var m = HashMap<u64, u64>::with_capacity(0)
    ck(m.size() == 0 && m.capacity() == 0, "with_capacity(0) allocates nothing")
    var w = HashMap<u64, u64>::with_capacity(100)
    ck(w.size() == 0 && w.capacity() >= 100, "with_capacity(100)")
    var cap = w.capacity()
    for var i: u64 = 0; i < 100; i += 1 { w.insert(i, i) }
    ck(w.capacity() == cap, "no growth while filling to the requested capacity")
    var o = HashMap<u64, Obj>::with_capacity(10)
    ck(o.is_empty() && live == 0, "with_capacity of move-only values")
}

fn test_literal() {
    var one: {u64: u64} = {1: 10}
    ck(one.size() == 1 && one[1] == 10, "literal: one")
    var l: {u64: u64} = {1: 10, 2: 20, 3: 30}
    ck(l.size() == 3 && l.entries()[0].key == 1 && l.entries()[2].key == 3, "literal: written order")
    var rep: {u64: u64} = {1: 10, 2: 20, 1: 11}
    ck(rep.size() == 2 && rep[1] == 11, "literal: repeated key takes the last value")
    ck(rep.entries()[0].key == 1 && rep.entries()[1].key == 2, "literal: repeated key keeps its first place")
    var s: {string: u64} = {"b": 1, "a": 2, "b": 3}
    ck(s.size() == 2 && s["b"] == 3 && s["a"] == 2, "literal: string keys")
    ck(s.entries()[0].key == "b" && s.entries()[1].key == "a", "literal: string key order")
}

fn test_from_iter() {
    var e = HashMap<u64, u64>::from_iter(Seq(0), 0)
    ck(e.is_empty(), "from_iter: empty")
    var o = HashMap<u64, u64>::from_iter(Seq(1), 1)
    ck(o.size() == 1 && o[0] == 0, "from_iter: one")
    var m = HashMap<u64, u64>::from_iter(Seq(500), 500)
    ck(m.size() == 500 && in_order(m, 500), "from_iter: many, in order")
    var h = HashMap<u64, u64>::from_iter(Seq(500), 0)
    ck(h.size() == 500 && in_order(h, 500), "from_iter: a hint of 0 still holds everything")
}

fn test_from_slice() {
    var items: [(u64, u64)] = [(3, 30), (4, 40), (3, 31)]
    var s = HashMap<u64, u64>::from_slice(items)
    ck(s.size() == 2 && s[3] == 31 && s[4] == 40, "from_slice: a later key replaces an earlier one")
    ck(s.entries()[0].key == 3 && s.entries()[1].key == 4, "from_slice: order")
    var none: [(u64, u64)]
    var e = HashMap<u64, u64>::from_slice(none)
    ck(e.is_empty(), "from_slice: empty")
    var strs: [(string, string)] = [("a".copy(), "x".copy()), ("b".copy(), "y".copy())]
    var t = HashMap<string, string>::from_slice(strs)
    ck(t.size() == 2 && t["a"] == "x" && t["b"] == "y", "from_slice: strings")
    ck(strs.size() == 2 && strs[0].0 == "a", "from_slice: the source is untouched")
}

fn test_move() {
    var a: {u64: u64}
    var b = a
    ck(b.is_empty(), "move of an empty map")
    var m = HashMap<u64, u64>::from_iter(Seq(500), 500)
    var cap = m.capacity()
    var n = m
    ck(n.size() == 500 && in_order(n, 500) && n.capacity() == cap, "move keeps contents, order and block")
    var one: {u64: u64} = {7: 70}
    var o = one
    ck(o.size() == 1 && o[7] == 70, "move of one entry")
    var s: {string: string} = {"k": "v"}
    var t = s
    ck(t["k"] == "v" && t.size() == 1, "move of a string map")
}

fn test_copy() {
    var e: {u64: u64}
    var ce = e.copy()
    ck(ce.is_empty() && ce.capacity() == 0, "copy of an empty map")
    var m = HashMap<u64, u64>::from_iter(Seq(300), 300)
    var c = m.copy()
    ck(c.size() == 300 && in_order(c, 300), "copy: contents and order")
    c[5] = 1
    c.insert(1000, 1)
    ck(m[5] == 50 && !m.contains(1000) && m.size() == 300, "copy is independent")
    m.swap_remove(0)
    ck(c.contains(0) && c.size() == 301, "removal from the original leaves the copy")
    var s: {string: string} = {"a": "1", "b": "2", "c": "3"}
    var sc = s.copy()
    s.clear()
    ck(sc.size() == 3 && sc["b"] == "2" && sc.entries()[0].key == "a", "copy of string entries is deep")
    var one: {u64: u64} = {9: 90}
    var oc = one.copy()
    ck(oc.size() == 1 && oc[9] == 90, "copy of one entry")
}

fn test_copy_of_copy_chain() {
    var m: {string: u64}
    for var i: u64 = 0; i < 100; i += 1 { m.insert(f"key{i}", i) }
    var c1 = m.copy()
    var c2 = c1.copy()
    c1.clear()
    var bad: u64 = 0
    for var i: u64 = 0; i < 100; i += 1 {
        var *v? = c2.get(f"key{i}")
        if !v? || *v != i { bad += 1 }
    }
    ck(bad == 0 && c2.size() == 100 && m.size() == 100, "a copy of a copy outlives its source")
}

fn test_counted_values() {
    {
        var m: {u64: Obj}
        for var i: u64 = 0; i < 50; i += 1 { m.insert(i, Obj(i)) }
        ck(live == 50, "move-only values: one live object per entry")
        var n = m
        ck(live == 50 && n.size() == 50, "move construction creates no object")
        var q = HashMap<u64, Obj>::with_capacity(5)
        ck(live == 50, "with_capacity creates no object")
    }
    ck(live == 0 && errors == 0, "construct: nothing leaked, nothing destroyed twice")
}

fn test_move_assign_and_swap() {
    {
        var a: {u64: Obj}
        var b: {u64: Obj}
        for var i: u64 = 0; i < 10; i += 1 { a.insert(i, Obj(i)) }
        for var i: u64 = 0; i < 20; i += 1 { b.insert(i + 100, Obj(i)) }
        ck(live == 30, "assign: two maps built")
        a = b
        ck(live == 20, "assigning a map over another destroys the old entries")
        ck(a.size() == 20 && a[105].v == 5 && !a.contains(0), "assign: the new contents")
        b = {}
        ck(b.is_empty() && live == 20, "assigning an empty literal to a moved-from map")
        var t = a
        a = b
        b = t
        ck(a.is_empty() && b.size() == 20 && b[119].v == 19 && live == 20, "swap by three moves")
    }
    ck(live == 0 && errors == 0, "assign: nothing leaked, nothing destroyed twice")
    var x: {u64: u64} = {1: 1}
    var y: {u64: u64} = {2: 2, 3: 3}
    var t = x
    x = y
    y = t
    ck(x.size() == 2 && y.size() == 1 && x[3] == 3 && y[1] == 1, "swap of plain maps")
}

fn main() -> i32 {
    test_default_is_empty()
    test_with_capacity()
    test_literal()
    test_from_iter()
    test_from_slice()
    test_move()
    test_copy()
    test_copy_of_copy_chain()
    test_counted_values()
    test_move_assign_and_swap()
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
