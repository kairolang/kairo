// Every HashSet member on an empty, a one-element and a many-element set,
// the set algebra with its order rules, and the operators with the set on
// both sides. The table's structure is checked after each mutation.

import std::io
import self::inputs::table_peek::*

var checks: u64 = 0
var failures: u64 = 0

fn ck(cond: bool, const what: string) {
    checks += 1
    if !cond {
        failures += 1
        io::println(f"FAIL {what}")
    }
}

fn oks(const s: {u64}, const what: string) {
    ck(tp_ok(const &s, what), what)
}

fn odd(x: *const u64) -> bool { return *x % 2 == 1 }

fn range(lo: u64, hi: u64) -> {u64} {
    var s: {u64}
    for var i = lo; i < hi; i += 1 { s.insert(i) }
    return s
}

fn order(const s: {u64}) -> [u64] {
    var v: [u64]
    for x in s { v.push(x) }
    return v
}

fn same(const a: [u64], const b: [u64]) -> bool {
    if a.size() != b.size() { return false }
    for var i: usize = 0; i < a.size(); i += 1 {
        if a[i] != b[i] { return false }
    }
    return true
}

class Upto {
    var i: u64
    var n: u64
    pub fn Upto(self, n: u64) {
        self.i = 0
        self.n = n
    }
}

extend Upto impl Iterator {
    type Item = u64
    fn next(self) -> u64? {
        if self.i == self.n { return null }
        self.i += 1
        return self.i - 1
    }
}

fn test_basic() {
    var e: {u64}
    ck(e.size() == 0 && e.is_empty() && e.capacity() == 0, "empty")
    ck(!e.contains(1) && !(1u64 in e) && !e.get(1)? && !e.first()? && !e.last()?, "empty lookups")
    ck(!e.swap_remove(1) && !e.shift_remove(1) && !e.take(1)? && !e.pop()?, "empty removals")
    ck(e.items().size() == 0, "empty items")
    oks(e, "empty")

    var s: {u64}
    ck(s.insert(5) && !s.insert(5) && s.size() == 1, "insert reports a new element")
    var r? = s.replace(5)
    ck(r? && r == 5 && s.size() == 1, "replace of a present element")
    r = s.replace(6)
    ck(!r? && s.size() == 2, "replace of a new element inserts")
    var t? = s.take(5)
    ck(t? && t == 5 && !s.contains(5), "take")
    var p? = s.pop()
    ck(p? && p == 6 && s.size() == 0, "pop")
    oks(s, "one")

    var m = range(0, 2000)
    oks(m, "many")
    var bad: u64 = 0
    for var i: u64 = 0; i < 2000; i += 1 {
        if !m.contains(i) || m.contains(i + 2000) { bad += 1 }
    }
    ck(bad == 0, "many lookups")
    var i: u64 = 0
    for x in m {
        if x != i { bad += 1 }
        i += 1
    }
    i = 0
    for x in m.items() {
        if x != i { bad += 1 }
        i += 1
    }
    ck(bad == 0, "iteration in insertion order")
    var *fp? = m.first()
    var *lp? = m.last()
    ck(fp? && lp? && *fp == 0 && *lp == 1999, "first and last")
    m.swap_remove(10)
    ck(m.items()[10] == 1999, "swap_remove moves the last element")
    m.shift_remove(20)
    ck(m.items()[20] == 21, "shift_remove keeps the order")
    m.retain(odd)
    bad = 0
    for x in m {
        if x % 2 == 0 { bad += 1 }
    }
    ck(bad == 0 && m.size() == 1000, "retain")
    oks(m, "after retain")
    var c = m.copy()
    ck(c == m && same(order(c), order(m)), "copy is equal and in order")
    c.insert(2)
    ck(!m.contains(2) && !(c == m), "copy is deep")
    m.reserve(50000)
    ck(m.capacity() >= 50000, "reserve")
    m.shrink_to_fit()
    ck(m.capacity() < 50000 && m.size() == 1000, "shrink_to_fit")
    oks(m, "after shrink")
    m.clear()
    ck(m.size() == 0 && !m.contains(1), "clear")
    oks(m, "after clear")

    var lit: {u64} = {3, 1, 3, 2}
    ck(same(order(lit), [3, 1, 2]), "a literal keeps the first place of a repeated element")
    var w = HashSet<u64>::with_capacity(100)
    ck(w.capacity() >= 100, "with_capacity")
    var items: [u64] = [4, 5, 4]
    var f = HashSet<u64>::from_slice(items)
    ck(f.size() == 2, "from_slice")
    f.extend_from(items)
    ck(f.size() == 2, "extend_from")
    var g = HashSet<u64>::from_iter(Upto(300), 0)
    ck(g.size() == 300 && g.contains(299), "from_iter")
    oks(g, "from_iter")
}

fn test_algebra() {
    var a = range(0, 10)
    var b = range(5, 15)
    var u: [u64]
    for x in a.set_union(b) { u.push(*x) }
    ck(same(u, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]), "union: self, then the rest of o")
    var n: [u64]
    for x in a.set_intersection(b) { n.push(*x) }
    ck(same(n, [5, 6, 7, 8, 9]), "intersection")
    var small = range(7, 9)
    n = []
    for x in a.set_intersection(small) { n.push(*x) }
    ck(same(n, [7, 8]), "intersection walks the smaller set")
    var d: [u64]
    for x in a.set_difference(b) { d.push(*x) }
    ck(same(d, [0, 1, 2, 3, 4]), "difference")
    var x: [u64]
    for y in a.set_xor(b) { x.push(*y) }
    ck(same(x, [0, 1, 2, 3, 4, 10, 11, 12, 13, 14]), "symmetric difference")

    ck(small.is_subset(a) && !a.is_subset(small) && a.is_superset(small), "subset and superset")
    ck(!a.is_disjoint(b) && a.is_disjoint(range(100, 110)), "disjoint")
    ck(range(0, 0).is_subset(a) && a.is_subset(a), "edge subsets")
    var e1 = range(1, 4)
    var e2: {u64} = {3, 2, 1}
    ck(e1 == e2 && !(e1 == a), "equality ignores order")

    var i = range(0, 10)
    i &= b
    ck(same(order(i), [5, 6, 7, 8, 9]), "&= keeps the order")
    oks(i, "&=")
    var m = range(0, 10)
    m -= b
    ck(same(order(m), [0, 1, 2, 3, 4]), "-=")
    oks(m, "-=")
    var o = range(0, 10)
    o |= b
    ck(same(order(o), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]), "|= appends what is missing")
    oks(o, "|=")
    var z = range(0, 10)
    z ^= b
    ck(same(order(z), [0, 1, 2, 3, 4, 10, 11, 12, 13, 14]), "^= keeps the survivors, then o's new elements")
    oks(z, "^=")

    // The set on both sides.
    var s1 = range(0, 50)
    s1 &= s1
    ck(s1.size() == 50, "s &= s")
    s1 |= s1
    ck(s1.size() == 50, "s |= s")
    s1 -= s1
    ck(s1.size() == 0, "s -= s")
    var s2 = range(0, 50)
    s2 ^= s2
    ck(s2.size() == 0, "s ^= s")
    oks(s1, "self ops")
    oks(s2, "self xor")
}

fn main() -> i32 {
    test_basic()
    test_algebra()
    io::println(f"{checks} checks, {failures} failures")
    return failures as i32
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: {{[0-9]+}} checks, 0 failures
