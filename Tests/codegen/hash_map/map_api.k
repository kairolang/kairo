// `{K: V}` (Lib/builtin/containers/hash_map.k): every entry of the API
// Compiler/ uses of Stage 0's map / unordered_map (the API surface list
// is kept outside the repo), with integer and string keys. Each check returns its own
// number on failure; 100 is success.

fn main() -> i32 {
    // default ctor, size / is_empty, `[]` as a place inserting a default value
    var m: {i32: i32}
    if !m.is_empty() || (m.size() != 0) { return 1 }
    m[7] += 0; if m[7] != 0 { return 2 }            // inserted, default 0
    if (m.size() != 1) || !m.contains(7) { return 3 }
    m[7] = 70
    m[8] += 8                                       // a place: default, then +=
    if (m[7] != 70) || (m[8] != 8) { return 4 }

    // try_insert: null for a new key; a present key keeps its value and the
    // new one comes back
    if m.try_insert(9, 90)? { return 5 }
    if !m.try_insert(9, 99)? { return 6 }
    if m[9] != 90 { return 7 }
    if m.try_insert(10, 100)? || !m.try_insert(10, 1)? { return 8 }

    // get, get_mut
    if m.get(11)? { return 9 }
    var *e? = m.get_mut(9)
    if !m.contains(9) || !e? || (*e != 90) { return 10 }
    *e = 91
    if m[9] != 91 { return 11 }
    if m.get(11) != null { return 12 }
    var *g = unwrap!(m.get_mut(10))
    *g = 101
    if m[10] != 101 { return 13 }

    // entries() walks them in insertion order
    var keys = 0
    for *en in m.entries() { keys = keys * 100 + en->key }
    if keys != 7080910 { return 14 }

    // `for (k, v) in m` and entries(), insertion order
    var sum = 0
    var order = 0
    for (k, v) in m { sum += v; order = order * 100 + k }
    if (sum != 70 + 8 + 91 + 101) || (order != 7080910) { return 15 }
    var n = 0
    for *en in m.entries() { n += en->key }
    if n != 34 { return 16 }

    // swap_remove: the value when it was there; the last entry moves in
    if !m.swap_remove(7)? || m.swap_remove(7)? { return 17 }
    order = 0
    for (k, v) in m { order = order * 100 + k }
    if order != 100809 { return 18 }                // 10 took 7's place
    // shift_remove keeps the others' order
    if !m.shift_remove(8)? { return 19 }
    order = 0
    for (k, v) in m { order = order * 100 + k }
    if order != 1009 { return 20 }

    // copy() is deep: the copies are independent; `=` moves
    var c = m.copy()
    c[10] = -1
    c[42] = 42
    if (m[10] != 101) || m.contains(42) { return 21 }
    var d: {i32: i32}
    d[1] = 1
    d = c.copy()
    if (d.size() != 3) || (d[42] != 42) || d.contains(1) { return 22 }
    c.clear()
    if (d.size() != 3) || (c.size() != 0) { return 23 }

    // clear keeps the capacity; reserve grows without inserting
    var cap = d.capacity()
    d.clear()
    if !d.is_empty() || (d.capacity() != cap) || d.contains(42) { return 24 }
    d.reserve(1000)
    if (d.capacity() < 1000) || (d.size() != 0) { return 25 }
    d[5] = 5
    if d[5] != 5 { return 26 }

    // string keys
    var s: {string: i32}
    s["one"] = 1
    s["two"] = 2
    s["three"] = 3
    if (s["two"] != 2) || !s.contains("three") || s.contains("four") { return 27 }
    if !s.swap_remove("one")? || (s.size() != 2) { return 28 }
    var t = s.copy()
    t["two"] = 22
    if s["two"] != 2 { return 29 }
    if s.contains("one") { return 30 }

    // literals: written order; a repeated key keeps its first place, last value
    var lit: {string: i32} = {"a": 1, "b": 2, "a": 3}
    if (lit.size() != 2) || (lit["a"] != 3) { return 31 }
    order = 0
    for (k, v) in lit { order = order * 10 + v }
    if order != 32 { return 32 }
    var empty: {i32: i32} = {}
    if empty.size() != 0 { return 33 }

    // emptied by swap_remove, then reused; reserve keeps every key.
    var r: {i32: i32}
    var i = 0
    while i < 20 { r[i] = i; i += 1 }
    i = 0
    while i < 20 { if !r.swap_remove(i)? { return 34 }; i += 1 }
    r[100] = 1
    r[200] = 2
    if (r.size() != 2) || (r[100] != 1) || (r[200] != 2) || r.contains(5) { return 35 }
    i = 0
    while i < 20 { r[i] = i; i += 1 }
    r.reserve(5000)
    i = 0
    while i < 20 { if !r.contains(i) || (r[i] != i) { return 36 }; i += 1 }
    var walked = 0
    for *en in r.entries() { walked += 1 }
    if walked != 22 { return 37 }
    return 100
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 100
