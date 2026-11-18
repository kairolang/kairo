// Lookup members of HashMap<K, V>: contains, `in`, get, get_mut, get_entry,
// first, last and get_or, on empty, one-entry and many-entry maps, with
// integer, string and move-only counted elements. A miss yields null (or the
// fallback); only the index form `m[k]` traps on a miss (see the trap tests).
//
// Cases from libc++ test/std/containers/unord/unord.map/ (find, count, contains)
// Cases from Rust library/std/src/collections/hash/map/tests.rs
// Cases from hashbrown src/map.rs tests (find, find_mut, empty lookups)

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

fn pair_sum(const m: {u64: u64}) -> u64 {
    var s: u64 = 0
    for (k, v) in m { s += k + v }
    return s
}

fn test_lookup_empty() {
    var m: {u64: u64}
    ck(!m.contains(0) && !m.contains(1), "empty: contains")
    ck(!(0u64 in m), "empty: in")
    ck(!m.get(0)?, "empty: get")
    ck(!m.get_mut(0)?, "empty: get_mut")
    ck(!m.get_entry(0)?, "empty: get_entry")
    ck(!m.first()? && !m.last()?, "empty: first and last")
    ck(m.get_or(1, 77) == 77, "empty: get_or returns the fallback")
    var s: {string: string}
    ck(!s.contains("") && !s.get("")?, "empty string map: miss")
}

fn test_lookup_one() {
    var m: {u64: u64} = {4: 40}
    ck(m.contains(4) && !m.contains(5) && !m.contains(0), "one: contains")
    ck(4u64 in m && !(5u64 in m), "one: in")
    var *p? = m.get(4)
    ck(p? && *p == 40, "one: get hit")
    ck(!m.get(5)?, "one: get miss")
    var *q? = m.get_mut(4)
    if q? { *q = 41 }
    ck(m[4] == 41, "one: get_mut writes through")
    var e? = m.get_entry(4)
    ck(e? && e->key == 4 && e->value == 41, "one: get_entry")
    var f? = m.first()
    var l? = m.last()
    ck(f? && l? && f->key == 4 && l->key == 4, "one: first and last are the same entry")
    ck(m.get_or(4, 0) == 41 && m.get_or(5, 9) == 9, "one: get_or")
}

fn test_lookup_many() {
    var m: {u64: u64}
    for var i: u64 = 0; i < 5000; i += 1 { m.insert(i * 3, i) }
    var bad: u64 = 0
    for var i: u64 = 0; i < 5000; i += 1 {
        var *p? = m.get(i * 3)
        if !p? || *p != i { bad += 1 }
        if !m.contains(i * 3) || m[i * 3] != i { bad += 1 }
        if m.contains(i * 3 + 1) || m.contains(i * 3 + 2) { bad += 1 }
        if m.get(i * 3 + 1)? { bad += 1 }
    }
    ck(bad == 0, "many: hits, and the two misses between each hit")
    var f? = m.first()
    var l? = m.last()
    ck(f? && f->key == 0 && f->value == 0, "many: first is the first inserted")
    ck(l? && l->key == 14997 && l->value == 4999, "many: last is the last inserted")
    ck(m.get_or(3, 0) == 1 && m.get_or(4, 123) == 123, "many: get_or")
    var *g? = m.get_mut(300)
    if g? { *g += 1000 }
    ck(m[300] == 1100, "many: get_mut")
    var e? = m.get_entry(30)
    ck(e? && e->value == 10 && !m.get_entry(31)?, "many: get_entry")
    ck(pair_sum(m) > 0, "many: sum")
}

fn test_get_mut_through_pointer() {
    var m: {u64: u64} = {1: 1, 2: 2, 3: 3}
    for var i: u64 = 1; i <= 3; i += 1 {
        var *p? = m.get_mut(i)
        if p? { *p = *p * 100 }
    }
    ck(m[1] == 100 && m[2] == 200 && m[3] == 300, "get_mut on every key")
}

fn test_string_keys() {
    var m: {string: u64}
    m.insert("alpha".copy(), 1)
    m.insert("beta".copy(), 2)
    m.insert("".copy(), 3)
    var probe = "al".copy()
    probe = f"{probe}pha"
    ck(m.contains(probe) && m[probe] == 1, "string: found by an equal string built separately")
    ck(m[""] == 3 && m.contains(""), "string: the empty key")
    ck(!m.contains("alph") && !m.contains("alphaa") && !m.contains("Alpha"), "string: near misses")
    ck("beta" in m && !("gamma" in m), "string: in")
    var *p? = m.get("beta")
    ck(p? && *p == 2, "string: get")
    var e? = m.get_entry("beta")
    ck(e? && e->key == "beta", "string: get_entry gives the stored key")
    var f? = m.first()
    ck(f? && f->key == "alpha", "string: first")
}

fn test_equal_but_distinct_keys() {
    var m: {string: Obj}
    m.insert("same".copy(), Obj(1))
    var k = "sa".copy()
    k = f"{k}me"
    var *p? = m.get(k)
    ck(p? && p->v == 1 && live == 1, "counted: lookup by a distinct equal key")
    var *q? = m.get_mut(k)
    if q? { q->v = 9 }
    ck(m["same"].v == 9, "counted: get_mut through a distinct equal key")
}

fn test_counted_lookup() {
    {
        var m: {u64: Obj}
        for var i: u64 = 0; i < 200; i += 1 { m.insert(i, Obj(i + 1)) }
        var bad: u64 = 0
        for var i: u64 = 0; i < 200; i += 1 {
            var *p? = m.get(i)
            if !p? || p->v != i + 1 { bad += 1 }
        }
        ck(bad == 0 && live == 200, "counted: lookups create and destroy nothing")
    }
    ck(live == 0 && errors == 0, "lookup: nothing leaked, nothing destroyed twice")
}

fn main() -> i32 {
    test_lookup_empty()
    test_lookup_one()
    test_lookup_many()
    test_get_mut_through_pointer()
    test_string_keys()
    test_equal_but_distinct_keys()
    test_counted_lookup()
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
