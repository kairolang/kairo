// Looking elements up and walking a HashSet: contains, the `in` operator, get, first, last, items
// and the `for` loop, on empty, one and many elements, with integers, strings, a record whose
// equal elements differ in other fields, and counted elements. Iteration is in insertion order
// (the type's doc comment: "Insertion-ordered").
//
// Cases from libc++ test/std/containers/unord/unord.set/ (find_const, find_non_const, count,
// contains, iterators, equal_range_const, equal_range_non_const)
// Cases from Rust library/std/src/collections/hash/set/tests.rs (test_iterate, test_from_iter,
// test_replace)
//
// Not ported, with the reason: equal_range (a set has no ranges of equal elements, so it is the
// same as get), bucket and local-iterator queries (no buckets), transparent lookup with a
// different key type (lookup takes `const T`), iterator concept and compile checks.

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

struct Rec {
    pub var id: u64
    pub var tag: u64
}

extend Rec impl Hash {
    fn hash(const self, @inout h: Hasher) {
        h.write_u64(self.id)
    }

    fn op == (const self, const o: Rec) -> bool {
        return self.id == o.id
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

fn range(lo: u64, hi: u64) -> {u64} {
    var s: {u64}
    for var i = lo; i < hi; i += 1 { s.insert(i) }
    return s
}

fn test_empty() {
    var e: {u64}
    ck(!e.contains(0) && !e.contains(1), "contains on an empty set")
    ck(!(0u64 in e), "in on an empty set")
    ck(!e.get(0)?, "get on an empty set")
    ck(!e.first()? && !e.last()?, "first and last of an empty set")
    ck(e.items().size() == 0, "items of an empty set")
    var n: u64 = 0
    for x in e { n += 1 }
    ck(n == 0, "iteration of an empty set")
    var es: {string}
    ck(!es.contains("") && !es.contains("a"), "contains on an empty string set")
}

fn test_one() {
    var s: {u64} = {42}
    ck(s.contains(42) && !s.contains(41) && !s.contains(43), "contains in a one-element set")
    ck(42u64 in s && !(7u64 in s), "in on a one-element set")
    var *g? = s.get(42)
    ck(g? && *g == 42, "get finds the element")
    ck(!s.get(7)?, "get of an absent element")
    var *f? = s.first()
    var *l? = s.last()
    ck(f? && l? && *f == 42 && *l == 42, "first and last are the one element")
    ck(s.items().size() == 1 && s.items()[0] == 42, "items of one")
}

fn test_many() {
    var s = range(0, 5000)
    var bad: u64 = 0
    for var i: u64 = 0; i < 5000; i += 1 {
        if !s.contains(i) || !(i in s) { bad += 1 }
        if s.contains(i + 5000) || (i + 5000) in s { bad += 1 }
    }
    ck(bad == 0, "contains and in over 5000 elements and 5000 misses")
    var *g? = s.get(1234)
    ck(g? && *g == 1234, "get in a big set")
    var *f? = s.first()
    var *l? = s.last()
    ck(f? && l? && *f == 0 && *l == 4999, "first and last of a big set")
    var i: u64 = 0
    for x in s {
        if x != i { bad += 1 }
        i += 1
    }
    ck(bad == 0 && i == 5000, "iteration runs in insertion order")
    i = 0
    for x in s.items() {
        if x != i { bad += 1 }
        i += 1
    }
    ck(bad == 0 && i == 5000 && s.items().size() == 5000, "items runs in insertion order")
    var observed: u64 = 0
    var small = range(0, 32)
    for x in small { observed |= 1 << x }
    ck(observed == 0xFFFFFFFF, "iteration reaches every one of 32 elements")
}

fn test_get_stored_element() {
    var s: {Rec}
    s.insert(Rec { id: 1, tag: 11 })
    s.insert(Rec { id: 2, tag: 22 })
    var *p? = s.get(Rec { id: 2, tag: 0 })
    ck(p? && p->tag == 22, "get returns the stored element, not the probe")
    var *q? = s.get(Rec { id: 3, tag: 0 })
    ck(!q?, "get of an absent record")
    ck(s.contains(Rec { id: 1, tag: 999 }), "equality ignores the other fields")
    var *a? = s.get(Rec { id: 2, tag: 0 })
    var *b? = s.get(Rec { id: 2, tag: 5 })
    ck(a? && b? && a == b, "equal probes find the same element")
}

fn test_pointers_stay_until_change() {
    var s = range(0, 10)
    var *p? = s.get(4)
    var *q? = s.get(4)
    ck(p? && q? && p == q, "get is stable between calls")
    var *f? = s.first()
    ck(f? && *f == 0, "first before a change")
    s.insert(10)
    var *f2? = s.first()
    ck(f2? && *f2 == 0, "first after an insert")
    var *l? = s.last()
    ck(l? && *l == 10, "last after an insert")
}

fn test_strings() {
    var s: {string} = {"alpha", "beta", "gamma", "delta"}
    ck(s.contains("alpha") && s.contains("delta") && !s.contains("epsilon"), "string lookups")
    ck(!s.contains("Alpha") && !s.contains("alph") && !s.contains("alphas"), "lookups are exact")
    var *g? = s.get("gamma")
    ck(g? && *g == "gamma", "get of a string")
    var *f? = s.first()
    var *l? = s.last()
    ck(f? && l? && *f == "alpha" && *l == "delta", "first and last strings")
    var joined: string = ""
    for const *w in s { joined += *w }
    ck(joined == "alphabetagammadelta", "iteration of strings in order")
    var key: string = "be"
    key += "ta"
    ck(s.contains(key), "a string built at run time is found")
    var many: {string}
    for var i: u32 = 0; i < 2000; i += 1 { many.insert(f"key-{i}") }
    var bad: u32 = 0
    for var i: u32 = 0; i < 2000; i += 1 {
        if !many.contains(f"key-{i}") { bad += 1 }
        if many.contains(f"nokey-{i}") { bad += 1 }
    }
    ck(bad == 0 && many.size() == 2000, "two thousand string keys")
}

fn test_counted() {
    {
        var s: {Ctr}
        for var i: u64 = 0; i < 10; i += 1 { s.insert(Ctr(i)) }
        var hit = s.contains(Ctr(3))
        var miss = s.contains(Ctr(33))
        ck(hit && !miss, "lookups with counted probes")
        var *g? = s.get(Ctr(9))
        ck(g? && g->v == 9, "get with a counted probe")
        var sum: u64 = 0
        for const *x in s { sum += x->v }
        ck(sum == 45, "iteration over counted elements")
        ck(live == 10, "lookups make no copies and leave no probe alive")
    }
    ck(live == 0 && errors == 0, "nothing is left, nothing destroyed twice")
}

fn main() -> i32 {
    test_empty()
    test_one()
    test_many()
    test_get_stored_element()
    test_pointers_stay_until_change()
    test_strings()
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
