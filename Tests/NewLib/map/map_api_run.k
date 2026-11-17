// Every HashMap member on an empty map, a one-entry map and a many-entry
// map, with the table's structure checked after each mutation. A failed
// check prints a FAIL line; the run ends with the number of checks.

import std::io
import self::Inputs::table_peek::*

var checks: u64 = 0
var failures: u64 = 0

fn ck(cond: bool, const what: string) {
    checks += 1
    if !cond {
        failures += 1
        io::println(f"FAIL {what}")
    }
}

fn okm(const m: {u64: u64}, const what: string) {
    ck(tp_ok(const &m, what), what)
}

fn twice(k: *const u64, v: *u64) -> bool {
    *v = *v * 2
    return *k % 3 != 0
}

fn add(a: u64, b: u64) -> u64 { return a + b }

fn make_seven() -> u64 { return 7 }

struct Count {
    pub var n: u64
}

extend Count impl Default {
    static fn make_default() -> Count { return Count { n: 0 } }
}

/// Yields (i, i * 10) for i in [0, n).
class Pairs {
    var i: u64
    var n: u64
    pub fn Pairs(self, n: u64) {
        self.i = 0
        self.n = n
    }
}

extend Pairs impl Iterator {
    type Item = (u64, u64)
    fn next(self) -> (u64, u64)? {
        if self.i == self.n { return null }
        var r = (self.i, self.i * 10)
        self.i += 1
        return r
    }
}

fn test_empty() {
    var m: {u64: u64}
    ck(m.size() == 0 && m.is_empty() && m.capacity() == 0, "empty: size and capacity")
    ck(!m.contains(1) && !(1u64 in m), "empty: contains")
    ck(!m.get(1)?, "empty: get")
    ck(!m.get_mut(1)?, "empty: get_mut")
    ck(!m.get_entry(1)?, "empty: get_entry")
    ck(!m.first()? && !m.last()?, "empty: first and last")
    ck(!m.swap_remove(1)? && !m.shift_remove(1)?, "empty: removal")
    ck(!m.pop()?, "empty: pop")
    m.clear()
    m.shrink_to_fit()
    m.reserve(0)
    ck(m.capacity() == 0, "empty: nothing allocated")
    ck(m.entries().size() == 0, "empty: entries")
    var n: u64 = 0
    for (k, v) in m { n += 1 }
    for k in m.keys() { n += 1 }
    for v in m.values() { n += 1 }
    ck(n == 0, "empty: iteration")
    var c = m.copy()
    ck(c.size() == 0 && c.capacity() == 0, "empty: copy")
    okm(m, "empty")
}

fn test_one() {
    var m: {u64: u64}
    var old? = m.insert(5, 50)
    ck(!old?, "one: insert of a new key returns null")
    ck(m.size() == 1 && m.capacity() == 7, "one: first growth to 7")
    ck(m[5] == 50 && m.contains(5) && !m.contains(6), "one: lookup")
    var f? = m.first()
    var l? = m.last()
    ck(f? && l? && f->key == 5 && l->value == 50, "one: first and last")
    old = m.insert(5, 51)
    ck(old? && old == 50 && m[5] == 51 && m.size() == 1, "one: insert replaces and returns the old value")
    var back? = m.try_insert(5, 52)
    ck(back? && back == 52 && m[5] == 51, "one: try_insert on a present key hands the value back")
    var p? = m.pop()
    ck(p? && p.0 == 5 && p.1 == 51 && m.size() == 0, "one: pop")
    okm(m, "one: after pop")
    back = m.try_insert(6, 60)
    ck(!back? && m[6] == 60, "one: try_insert on a new key")
    var r? = m.swap_remove(6)
    ck(r? && r == 60 && m.size() == 0 && !m.contains(6), "one: swap_remove of the only entry")
    okm(m, "one: after swap_remove")
}

fn test_many() {
    const n: u64 = 3000
    var m: {u64: u64}
    for var i: u64 = 0; i < n; i += 1 {
        m.insert(i * 2654435761, i)
    }

    okm(m, "many: built")
    ck(m.size() == n as usize, "many: size")
    var bad: u64 = 0
    for var i: u64 = 0; i < n; i += 1 {
        var *v? = m.get(i * 2654435761)
        if !v? || *v != i { bad += 1 }
        if m.contains(i * 2654435761 + 1) { bad += 1 }
    }
    ck(bad == 0, "many: every key found, no false hit")

    // Iteration is insertion order, in all four forms.
    var i: u64 = 0
    bad = 0
    for (k, v) in m {
        if k != i * 2654435761 || v != i { bad += 1 }
        i += 1
    }
    ck(bad == 0 && i == n, "many: op in order")
    i = 0
    for k in m.keys() {
        if *k != i * 2654435761 { bad += 1 }
        i += 1
    }
    i = 0
    for v in m.values() {
        if *v != i { bad += 1 }
        i += 1
    }
    for v in m.values_mut() { *v = *v + 1 }
    i = 0
    for e in m.entries() {
        if e.key != i * 2654435761 || e.value != i + 1 { bad += 1 }
        i += 1
    }
    ck(bad == 0, "many: keys, values, values_mut, entries")
    for (k, *v) in m { *v = *v - 1 }
    ck(m[2654435761] == 1, "many: writing through iteration")

    // The setter and the place form.
    m[7] = 70
    ck(m[7] == 70 && m.size() == (n + 1) as usize, "many: setter inserts")
    m[7] = 71
    ck(m[7] == 71 && m.size() == (n + 1) as usize, "many: setter replaces")
    var cm: {u64: Count}
    cm[8].n += 5
    ck(cm[8].n == 5 && cm.size() == 1, "many: place form inserts the default")
    cm[8].n += 5
    ck(cm[8].n == 10 && cm.size() == 1, "many: place form updates")
    var *cd = cm.get_or_default(11)
    ck(cd->n == 0 && cm.contains(11), "many: get_or_default")
    okm(m, "many: after setters")

    var *g = m.get_or_insert(9, 90)
    ck(*g == 90, "many: get_or_insert on a miss")
    g = m.get_or_insert(9, 91)
    ck(*g == 90, "many: get_or_insert on a hit")
    g = m.get_or_insert_with(10, make_seven)
    ck(*g == 7, "many: get_or_insert_with")
    ck(m.get_or(12, 99) == 99 && m.get_or(9, 99) == 90, "many: get_or")
    var *gm? = m.get_mut(9)
    if gm? { *gm = 92 }
    ck(m[9] == 92, "many: get_mut")
    var *ge? = m.get_entry(9)
    ck(ge? && ge->key == 9 && ge->value == 92, "many: get_entry")
    okm(m, "many: after get_or_*")

    // Removal: shift keeps order, swap moves the last entry.
    var before = m.size()
    var lastk: u64 = 0
    var *lp? = m.last()
    if lp? { lastk = lp->key }
    var r? = m.swap_remove(2654435761 * 10)
    ck(r? && r == 10 && m.size() == before - 1, "many: swap_remove value")
    ck(m.entries()[10].key == lastk, "many: swap_remove moves the last entry into the hole")
    okm(m, "many: after swap_remove")
    r = m.shift_remove(2654435761 * 20)
    ck(r? && r == 20 && m.entries()[20].key == 2654435761 * 21, "many: shift_remove keeps order")
    okm(m, "many: after shift_remove")
    ck(!m.swap_remove(3)? && !m.shift_remove(3)?, "many: removal of an absent key")

    // retain and merge.
    m.retain(twice)
    bad = 0
    for (k, v) in m {
        if k % 3 == 0 { bad += 1 }
    }
    ck(bad == 0, "many: retain drops what keep refuses")
    okm(m, "many: after retain")
    var o: {u64: u64} = {1: 100, 2: 200}
    o[7] = 1000
    var had7 = m.contains(7)
    var v7 = m.get_or(7, 0)
    m.merge(o, add)
    ck(m[1] == 100 && m[2] == 200, "many: merge moves new keys in")
    ck(!had7 || m[7] == v7 + 1000, "many: merge resolves a common key")
    okm(m, "many: after merge")

    // copy is deep and keeps order.
    var c = m.copy()
    ck(c.size() == m.size() && c.capacity() == m.capacity(), "many: copy size and capacity")
    bad = 0
    var idx: usize = 0
    for e in c.entries() {
        if e.key != m.entries()[idx].key || e.value != m.entries()[idx].value { bad += 1 }
        idx += 1
    }
    c[1] = 5
    ck(bad == 0 && m[1] == 100, "many: copy is deep and in order")
    okm(c, "many: the copy")

    // Capacity.
    var cap = m.capacity()
    m.reserve(m.size())
    ck(m.capacity() == cap, "many: reserve below capacity does nothing")
    m.reserve(100000)
    ck(m.capacity() >= 100000, "many: reserve")
    okm(m, "many: after reserve")
    m.shrink_to_fit()
    ck(m.capacity() < 100000 && m.capacity() >= m.size(), "many: shrink_to_fit")
    okm(m, "many: after shrink")
    m.clear()
    ck(m.size() == 0 && m.capacity() > 0 && !m.contains(1), "many: clear keeps the block")
    okm(m, "many: after clear")
    m.insert(1, 1)
    ck(m[1] == 1, "many: insert after clear")
    m.clear()
    m.shrink_to_fit()
    ck(m.capacity() == 0, "many: shrink of an empty map frees")
    okm(m, "many: released")
}

fn test_construction() {
    var lit: {u64: u64} = {1: 10, 2: 20, 1: 11}
    ck(lit.size() == 2 && lit[1] == 11 && lit.entries()[0].key == 1, "literal: a repeated key keeps its first place and takes its last value")
    var w = HashMap<u64, u64>::with_capacity(100)
    ck(w.capacity() >= 100 && w.size() == 0, "with_capacity")
    var items: [(u64, u64)] = [(3, 30), (4, 40), (3, 31)]
    var s = HashMap<u64, u64>::from_slice(items)
    ck(s.size() == 2 && s[3] == 31 && s[4] == 40, "from_slice")
    s.extend_from(items)
    ck(s.size() == 2, "extend_from")
    var it = HashMap<u64, u64>::from_iter(Pairs(500), 500)
    ck(it.size() == 500 && it[499] == 4990 && it.entries()[0].key == 0, "from_iter")
    okm(it, "from_iter")
    var moved = it
    ck(moved.size() == 500 && moved[3] == 30, "move construction")
}

fn main() -> i32 {
    test_empty()
    test_one()
    test_many()
    test_construction()
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
