// HashMap and HashSet with string keys: literal and owned keys of every
// length the hasher branches on (0, 1..3, 4..7, 8..16, 17 and longer),
// lookup by an equal string that is not the stored one, growth and removal
// moving keys, copy() duplicating them.

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

/// A key of `len` bytes that differs by `i`.
fn key(i: u64, len: u64) -> string {
    var s = f"{i}"
    while s.size() < len as usize {
        s = f"{s}#"
    }
    return s
}

fn test_lengths() {
    var m: {string: u64}
    var lens: [u64] = [0, 1, 2, 3, 4, 7, 8, 15, 16, 17, 31, 32, 33, 100]
    for l in lens {
        m.insert(key(l, l), l)
    }
    m.insert("", 1000)
    ck(m.size() == lens.size() + 1 && m[""] == 1000, "every length, and the empty key")
    var bad: u64 = 0
    for l in lens {
        var *v? = m.get(key(l, l))
        if !v? { bad += 1 }
    }
    ck(bad == 0, "found by an equal string built again")
    ck(m.contains("") || m.contains("0"), "literal lookup")
    ck(tp_ok(const &m, "lengths"), "consistent")
}

fn test_many() {
    var m: {string: u64}
    for var i: u64 = 0; i < 5000; i += 1 {
        m.insert(key(i, 6 + i % 40), i)
    }
    ck(m.size() == 5000 && tp_ok(const &m, "many"), "5000 owned keys through growth")
    var bad: u64 = 0
    for var i: u64 = 0; i < 5000; i += 1 {
        var *v? = m.get(key(i, 6 + i % 40))
        if !v? || *v != i { bad += 1 }
        if m.contains(key(i + 5000, 6 + i % 40)) { bad += 1 }
    }
    ck(bad == 0, "hits and misses")
    var j: u64 = 0
    for (const *k, v) in m {
        var *w? = m.get(*k)
        if !w? || *w != j || v != j || k->size() != (6 + j % 40) as usize { bad += 1 }
        j += 1
    }
    ck(bad == 0, "keys kept their bytes and order through growth")

    var fresh = key(9999, 9)
    m.insert(fresh.copy(), 2)
    var p? = m.pop()
    ck(p? && p.1 == 2 && p.0.size() == 9 && !m.contains(fresh), "pop moves the last key out")
    var r? = m.swap_remove(key(10, 16))
    ck(r? && r == 10 && !m.contains(key(10, 16)), "swap_remove")
    r = m.shift_remove(key(11, 17))
    ck(r? && r == 11, "shift_remove")
    ck(tp_ok(const &m, "after removals"), "consistent after removals")

    var c = m.copy()
    ck(c.size() == m.size() && tp_ok(const &c, "copy"), "copy")
    bad = 0
    for (const *k, v) in c {
        var *w? = m.get(*k)
        if !w? || *w != v { bad += 1 }
    }
    ck(bad == 0, "copy holds equal keys and values")
    m.clear()
    var k12 = key(12, 18)
    var kept = c.contains(k12)
    ck(kept && c.size() > 0, "copy survives the original's clear")
    m.shrink_to_fit()
}

fn test_set() {
    var s: {string}
    var words: [string] = ["alpha", "beta", "gamma", "delta", "beta"]
    for *w in words { s.insert(w->copy()) }
    ck(s.size() == 4 && s.contains("gamma") && !s.contains("epsilon"), "string set")
    var o: {string} = {"beta", "omega"}
    var u: [string]
    for x in s.set_union(o) { u.push(x->copy()) }
    ck(u.size() == 5 && u[4] == "omega", "union")
    s -= o
    ck(s.size() == 3 && !s.contains("beta"), "-=")
    ck(tp_ok(const &s, "set"), "consistent")
}

fn main() -> i32 {
    test_lengths()
    test_many()
    test_set()
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
