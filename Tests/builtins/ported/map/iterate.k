// Iteration over HashMap<K, V>: `for (k, v) in m`, keys(), values(),
// values_mut() and the entries() slice, on empty, one-entry and many-entry
// maps, with integer, string and move-only counted elements. Every form
// walks in insertion order, which a removal changes as swap_remove and
// shift_remove document.
//
// differs from C++ and Rust: iteration order is defined (insertion order);
// the sources' "order unspecified" cases assert it (hash_map.k, the doc
// comment on HashMap). There are no iterator objects, so iterator
// categories, invalidation tables and iterator equality have no counterpart.
//
// Cases from libc++ test/std/containers/unord/unord.map/ (iterators, begin and end, empty)
// Cases from Rust library/std/src/collections/hash/map/tests.rs
// Cases from hashbrown src/map.rs tests (iterate, keys, values, values_mut, empty iter)

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

fn sum_const(const m: {u64: u64}) -> u64 {
    var s: u64 = 0
    for (k, v) in m { s += v }
    return s
}

fn count_keys(const m: {string: u64}) -> u64 {
    var n: u64 = 0
    for k in m.keys() { n += 1 }
    return n
}

fn test_iterate_empty() {
    var m: {u64: u64}
    var n: u64 = 0
    for (k, v) in m { n += 1 }
    for k in m.keys() { n += 1 }
    for v in m.values() { n += 1 }
    for v in m.values_mut() { n += 1 }
    for e in m.entries() { n += 1 }
    ck(n == 0 && m.entries().size() == 0, "empty: every form yields nothing")
    ck(sum_const(m) == 0, "empty: const map")
}

fn test_iterate_one() {
    var m: {u64: u64} = {3: 30}
    var n: u64 = 0
    for (k, v) in m {
        ck(k == 3 && v == 30, "one: pair")
        n += 1
    }
    for k in m.keys() { ck(*k == 3, "one: key"); n += 1 }
    for v in m.values() { ck(*v == 30, "one: value"); n += 1 }
    for v in m.values_mut() { *v = 31; n += 1 }
    ck(n == 4 && m[3] == 31 && m.entries().size() == 1, "one: all forms ran once")
}

fn test_forms_agree_in_insertion_order() {
    var m: {u64: u64}
    for var i: u64 = 0; i < 1000; i += 1 { m.insert((i * 37) % 1009, i) }
    var bad: u64 = 0
    var i: u64 = 0
    for (k, v) in m {
        if k != (i * 37) % 1009 || v != i { bad += 1 }
        i += 1
    }
    ck(bad == 0 && i == 1000, "op in: insertion order")
    i = 0
    for k in m.keys() {
        if *k != (i * 37) % 1009 { bad += 1 }
        i += 1
    }
    ck(bad == 0 && i == 1000, "keys: insertion order")
    i = 0
    for v in m.values() {
        if *v != i { bad += 1 }
        i += 1
    }
    ck(bad == 0 && i == 1000, "values: insertion order")
    i = 0
    for e in m.entries() {
        if e.key != (i * 37) % 1009 || e.value != i { bad += 1 }
        i += 1
    }
    ck(bad == 0 && i == 1000 && m.entries().size() == 1000, "entries: insertion order and count")
    ck(sum_const(m) == 999 * 1000 / 2, "const map: sum of the values")
}

fn test_mutation_through_iteration() {
    var m: {u64: u64}
    for var i: u64 = 0; i < 100; i += 1 { m.insert(i, i) }
    for (const *k, *v) in m { *v = *v * 2 + *k }
    var bad: u64 = 0
    for var i: u64 = 0; i < 100; i += 1 {
        if m[i] != 3 * i { bad += 1 }
    }
    ck(bad == 0, "op in: writes through the value pointer")
    for v in m.values_mut() { *v += 1 }
    for var i: u64 = 0; i < 100; i += 1 {
        if m[i] != 3 * i + 1 { bad += 1 }
    }
    ck(bad == 0, "values_mut: writes every value")
    for (const *k, const *v) in m {
        if !m.get(*k)? { bad += 1 }
    }
    ck(bad == 0, "lookups during iteration")
    for var i: u64 = 0; i < 100; i += 1 {
        if m.entries()[i as usize].key != i { bad += 1 }
    }
    ck(bad == 0, "mutation does not reorder")
}

fn test_early_exit_and_nested() {
    var m: {u64: u64}
    for var i: u64 = 0; i < 50; i += 1 { m.insert(i, i) }
    var n: u64 = 0
    for (k, v) in m {
        if k == 9 { break }
        n += 1
    }
    ck(n == 9, "break leaves the loop")
    n = 0
    for (k, v) in m {
        if k % 2 == 1 { continue }
        n += 1
    }
    ck(n == 25, "continue skips an entry")
    var pairs: u64 = 0
    for (a, x) in m {
        for (b, y) in m {
            if a < 3 && b < 3 { pairs += 1 }
        }
    }
    ck(pairs == 9, "nested iteration of one map")
}

fn test_order_after_removal() {
    // swap_remove moves the last entry into the hole; shift_remove keeps the
    // order of the rest (hash_map.k doc comments).
    var m: {u64: u64}
    for var i: u64 = 0; i < 8; i += 1 { m.insert(i, i) }
    m.swap_remove(2)
    var got: [u64]
    for k in m.keys() { got.push(*k) }
    ck(got.size() == 7 && got[2] == 7 && got[0] == 0 && got[6] == 6, "iteration after swap_remove")
    m.shift_remove(0)
    var got2: [u64]
    for k in m.keys() { got2.push(*k) }
    ck(got2.size() == 6 && got2[0] == 1 && got2[1] == 7 && got2[5] == 6, "iteration after shift_remove")
    m.insert(2, 2)
    var last: u64 = 0
    for k in m.keys() { last = *k }
    ck(last == 2, "a re-inserted key goes last")
}

fn test_string_iteration() {
    var m: {string: u64}
    var names: [string] = ["zeta".copy(), "alpha".copy(), "mu".copy(), "beta".copy()]
    var i: u64 = 0
    for *nm in names {
        m.insert(nm->copy(), i)
        i += 1
    }
    var bad: u64 = 0
    i = 0
    for (const *k, v) in m {
        if *k != names[i as usize] || v != i { bad += 1 }
        i += 1
    }
    ck(bad == 0 && i == 4, "string keys: insertion order, not sorted order")
    ck(count_keys(m) == 4, "string keys: keys()")
    var t: {string: string}
    for var j: u64 = 0; j < 200; j += 1 { t.insert(f"k{j}", f"v{j}") }
    var j: u64 = 0
    for (const *k, const *v) in t {
        if *k != f"k{j}" || *v != f"v{j}" { bad += 1 }
        j += 1
    }
    ck(bad == 0 && j == 200, "string pairs: order and contents")
    for v in t.values_mut() { v->push_str("!") }
    ck(t["k0"] == "v0!" && t["k199"] == "v199!", "string values: values_mut appends")
}

fn test_counted_iteration() {
    {
        var m: {u64: Obj}
        for var i: u64 = 0; i < 100; i += 1 { m.insert(i, Obj(i)) }
        var total: u64 = 0
        for (const *k, const *v) in m { total += v->v }
        for v in m.values() { total += v->v }
        for (const *k, *v) in m { v->v += 1 }
        for v in m.values_mut() { v->v += 1 }
        for const *e in m.entries() { total += e->value.v }
        ck(live == 100, "counted: iteration creates and destroys nothing")
        ck(total == 4950 * 2 + (4950 + 200), "counted: values read and written through pointers")
    }
    ck(live == 0 && errors == 0, "iterate: nothing leaked, nothing destroyed twice")
}

fn main() -> i32 {
    test_iterate_empty()
    test_iterate_one()
    test_forms_agree_in_insertion_order()
    test_mutation_through_iteration()
    test_early_exit_and_nested()
    test_order_after_removal()
    test_string_iteration()
    test_counted_iteration()
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
