// Removing elements from a HashSet: swap_remove, shift_remove, take, pop, clear and retain, at the
// front, the middle and the back, on empty, one and many elements, with integers, strings and
// move-only counted elements. swap_remove and take move the last element into the hole
// (`swap_remove`'s doc comment: "the last element takes its place"); shift_remove, retain and
// pop keep the order of what remains (`shift_remove`: "later elements shift down, so insertion
// order is kept"; `retain`: "Keeps the elements `keep` accepts, in order").
//
// Cases from libc++ test/std/containers/unord/unord.set/ (erase_key, erase_if, clear, extract_key)
// Cases from Rust library/std/src/collections/hash/set/tests.rs (test_retain, test_zero_capacities)
//
// Not ported, with the reason: erase by iterator or iterator range and extract by iterator (no
// iterator-position API), drain (a set has none: listed as an API gap), extract_if (none).

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

class Ctr {
    pub var v: u64
    var state: u64

    pub fn Ctr(self, v: u64) {
        self.v = v
        self.state = 1
        live += 1
    }

    @move pub fn Ctr(self, other: Self) {
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

extend Ctr impl Hash {
    fn hash(const self, @inout h: Hasher) {
        h.write_u64(self.v)
    }

    fn op == (const self, const o: Ctr) -> bool {
        return self.v == o.v
    }
}

fn order(const s: {u64}) -> [u64] {
    var v: [u64]
    for x in s { v.push(x) }
    return v
}

fn is_order(const s: {u64}, const want: [u64]) -> bool {
    var o = order(s)
    if o.size() != want.size() { return false }
    for var i: usize = 0; i < o.size(); i += 1 {
        if o[i] != want[i] { return false }
    }
    return true
}

fn range(lo: u64, hi: u64) -> {u64} {
    var s: {u64}
    for var i = lo; i < hi; i += 1 { s.insert(i) }
    return s
}

fn corder(const s: {Ctr}) -> [u64] {
    var v: [u64]
    for const *x in s { v.push(x->v) }
    return v
}

fn odd(x: *const u64) -> bool { return *x % 2 == 1 }
fn none(x: *const u64) -> bool { return false }
fn all(x: *const u64) -> bool { return true }
fn small(x: *const u64) -> bool { return *x < 3 }

fn test_remove_key() {
    var c: {u64} = {1, 2, 3, 4, 1, 2}
    ck(!c.swap_remove(5) && c.size() == 4, "removing an absent key changes nothing")
    ck(c.swap_remove(2) && c.size() == 3, "removing a present key")
    ck(c.contains(1) && c.contains(3) && c.contains(4) && !c.contains(2), "the others stay")
    ck(!c.swap_remove(2) && c.size() == 3, "a second removal finds nothing")
    ck(c.shift_remove(4) && c.size() == 2, "shift_remove of a present key")
    ck(!c.shift_remove(4) && c.size() == 2, "a second shift_remove finds nothing")
    ck(c.swap_remove(1) && c.size() == 1 && c.contains(3), "down to one")
    ck(c.shift_remove(3) && c.size() == 0 && c.is_empty(), "down to none")
    ck(!c.swap_remove(3) && !c.shift_remove(3) && c.size() == 0, "removal from an empty set")
    var e: {u64}
    ck(!e.swap_remove(0) && !e.shift_remove(0) && !e.take(0)? && !e.pop()?, "an untouched empty set removes nothing")
}

fn test_swap_remove_order() {
    var s = range(0, 10)
    s.swap_remove(3)
    ck(is_order(s, [0, 1, 2, 9, 4, 5, 6, 7, 8]), "swap_remove moves the last into the hole")
    s.swap_remove(0)
    ck(is_order(s, [8, 1, 2, 9, 4, 5, 6, 7]), "swap_remove of the first")
    s.swap_remove(7)
    ck(is_order(s, [8, 1, 2, 9, 4, 5, 6]), "swap_remove of the last is a plain pop")
    var one: {u64} = {4}
    one.swap_remove(4)
    ck(one.is_empty(), "swap_remove of the only element")
    var two: {u64} = {4, 5}
    two.swap_remove(4)
    ck(is_order(two, [5]), "swap_remove of the first of two")
}

fn test_shift_remove_order() {
    var s = range(0, 10)
    s.shift_remove(3)
    ck(is_order(s, [0, 1, 2, 4, 5, 6, 7, 8, 9]), "shift_remove keeps the order")
    s.shift_remove(0)
    ck(is_order(s, [1, 2, 4, 5, 6, 7, 8, 9]), "shift_remove of the first")
    s.shift_remove(9)
    ck(is_order(s, [1, 2, 4, 5, 6, 7, 8]), "shift_remove of the last")
    var ok = true
    for var i: u64 = 0; i < 10; i += 1 {
        if s.contains(i) != (i != 0 && i != 3 && i != 9) { ok = false }
    }
    ck(ok, "lookups are right after shifting")
    s.insert(3)
    ck(is_order(s, [1, 2, 4, 5, 6, 7, 8, 3]) && s.contains(3), "a removed key can come back at the end")
}

fn test_remove_many() {
    var s = range(0, 3000)
    var bad: u64 = 0
    for var i: u64 = 0; i < 3000; i += 3 {
        if !s.swap_remove(i) { bad += 1 }
    }
    ck(bad == 0 && s.size() == 2000, "every third removed by swap_remove")
    for var i: u64 = 0; i < 3000; i += 1 {
        if s.contains(i) != (i % 3 != 0) { bad += 1 }
    }
    ck(bad == 0, "membership after many swap_removes")
    for var i: u64 = 1; i < 3000; i += 3 {
        if !s.shift_remove(i) { bad += 1 }
    }
    ck(bad == 0 && s.size() == 1000, "every third more removed by shift_remove")
    for x in s {
        if x % 3 != 2 { bad += 1 }
    }
    ck(bad == 0, "only the residue-2 keys remain")
    while s.size() > 0 {
        s.pop()
    }
    ck(s.is_empty() && !s.contains(2), "popped to empty")
    for var i: u64 = 0; i < 100; i += 1 { s.insert(i) }
    ck(s.size() == 100, "a drained set takes elements again")
}

fn test_take() {
    var s: {u64} = {5, 6, 7, 8}
    var t? = s.take(6)
    ck(t? && t == 6 && is_order(s, [5, 8, 7]), "take returns the element, last takes its place")
    var a? = s.take(100)
    ck(!a? && s.size() == 3, "take of an absent key")
    var l? = s.take(7)
    ck(l? && l == 7 && is_order(s, [5, 8]), "take of the last")
    var f? = s.take(5)
    ck(f? && f == 5 && is_order(s, [8]), "take of the first")
    var o? = s.take(8)
    ck(o? && s.is_empty(), "take of the only element")
    var ss: {string} = {"left", "mid", "right"}
    var w? = ss.take("mid")
    ck(w? && w == "mid" && ss.size() == 2 && !ss.contains("mid"), "take of a string")
    var m? = ss.take("zzz")
    ck(!m?, "take of an absent string")
}

fn test_pop() {
    var s = range(0, 5)
    var a? = s.pop()
    ck(a? && a == 4 && is_order(s, [0, 1, 2, 3]), "pop returns the last element")
    var n: u64 = 0
    while s.size() > 0 {
        var x? = s.pop()
        if !x? || x != 3 - n { errors += 1 }
        n += 1
    }
    ck(n == 4 && s.is_empty(), "pop yields the elements back to front")
    var e? = s.pop()
    ck(!e?, "pop of an empty set is null")
    var ss: {string} = {"a", "b"}
    var p? = ss.pop()
    ck(p? && p == "b" && ss.size() == 1, "pop of a string")
}

fn test_retain() {
    var s: {u64} = {1, 2, 3, 4, 5, 6}
    s.retain(odd)
    ck(is_order(s, [1, 3, 5]), "retain keeps the accepted in order")
    s.retain(all)
    ck(is_order(s, [1, 3, 5]), "retain of everything")
    s.retain(none)
    ck(s.is_empty(), "retain of nothing")
    s.retain(odd)
    ck(s.is_empty(), "retain of an empty set")
    var one: {u64} = {7}
    one.retain(odd)
    ck(one.size() == 1, "retain of one kept")
    one.retain(small)
    ck(one.is_empty(), "retain of one dropped")
    var m = range(0, 4000)
    m.retain(small)
    ck(is_order(m, [0, 1, 2]), "retain of a big set down to three")
    var bad: u64 = 0
    for var i: u64 = 0; i < 4000; i += 1 {
        if m.contains(i) != (i < 3) { bad += 1 }
    }
    ck(bad == 0, "lookups after retain")
    var n = range(0, 100)
    n.retain(odd)
    ck(n.size() == 50 && n.contains(99) && !n.contains(98), "retain of half")
}

fn test_clear() {
    var e: {u64}
    e.clear()
    ck(e.is_empty(), "clear of an empty set")
    var s = range(0, 1000)
    var cap = s.capacity()
    s.clear()
    ck(s.is_empty() && !s.contains(5) && !s.first()? && !s.last()?, "clear empties")
    ck(s.capacity() == cap, "clear keeps the capacity")
    s.insert(3)
    ck(s.size() == 1 && s.contains(3), "a cleared set takes elements again")
    var ss: {string} = {"a", "b"}
    ss.clear()
    ck(ss.is_empty() && !ss.contains("a"), "clear of strings")
}

fn test_counted() {
    {
        var s: {Ctr}
        for var i: u64 = 0; i < 40; i += 1 { s.insert(Ctr(i)) }
        ck(live == 40, "forty alive")
        s.swap_remove(Ctr(5))
        ck(live == 39, "swap_remove destroys the element")
        s.shift_remove(Ctr(6))
        ck(live == 38, "shift_remove destroys the element")
        var t? = s.take(Ctr(7))
        ck(t? && live == 37 + 1, "take hands the element out alive")
        t = null
        ck(live == 37, "the taken element dies with its handle")
        var p? = s.pop()
        ck(p? && p.v == 37, "pop of a counted element")
        p = null
        ck(live == 36, "the popped element dies with its handle")
        var gone = s.swap_remove(Ctr(5))
        ck(!gone && live == 36, "an absent key leaves the count")
        var o = corder(s)
        ck(o.size() == 36 && o[5] == 39 && o[6] == 38, "removals reordered as documented")
        s.shift_remove(Ctr(0))
        ck(corder(s)[0] == 1, "shift_remove of the first")
        s.clear()
        ck(live == 0 && s.is_empty(), "clear destroys all")
        for var i: u64 = 0; i < 30; i += 1 { s.insert(Ctr(i)) }
        s.retain(fn (x: *const Ctr) -> bool { return x->v % 3 == 0 })
        ck(s.size() == 10 && live == 10, "retain destroys the rejected")
    }
    ck(live == 0, "nothing is left")
    ck(errors == 0, "no use after a move and no double destroy")
}

fn main() -> i32 {
    test_remove_key()
    test_swap_remove_order()
    test_shift_remove_order()
    test_remove_many()
    test_take()
    test_pop()
    test_retain()
    test_clear()
    test_counted()
    io::println(f"{checks} checks, {failures} failures")
    return failures as i32
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: {{[0-9]+}} checks, 0 failures
