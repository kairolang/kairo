// Adding elements to a HashSet: insert, replace, extend_from, and the `|=` operator, on empty,
// one and many elements, with integers, strings, a record whose equal elements differ in other
// fields, and move-only counted elements. insert keeps the stored element and drops the new one
// (`insert`'s doc comment: "False, and `x` is dropped, when an equal element is already there");
// replace puts the new element in the place of the equal one and returns the old one (`replace`'s
// doc comment).
//
// Cases from libc++ test/std/containers/unord/unord.set/ (insert_*, emplace*)
// Cases from Rust library/std/src/collections/hash/set/tests.rs
//
// Not ported, with the reason: hinted insert and emplace_hint (no hint argument), emplace (an
// element is built by the caller and moved in), node handles and merge (no node type), insert of
// an iterator pair (extend_from takes a slice), allocator-requirement checks.

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
    pub var tag: u64
    var state: u64

    pub fn Ctr(self, v: u64, tag: u64) {
        self.v = v
        self.tag = tag
        self.state = 1
        live += 1
    }

    @move pub fn Ctr(self, other: Self) {
        if other.state != 1 { errors += 1 }
        self.v = other.v
        self.tag = other.tag
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

// Equal when `v` is equal; `tag` takes no part in hash or equality.
extend Ctr impl Hash {
    fn hash(const self, @inout h: Hasher) {
        h.write_u64(self.v)
    }

    fn op == (const self, const o: Ctr) -> bool {
        return self.v == o.v
    }
}

extend Ctr impl Copyable {
    fn copy(const self) -> Ctr {
        return Ctr(self.v, self.tag)
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

extend Rec impl Copyable {
    fn copy(const self) -> Rec {
        return Rec { id: self.id, tag: self.tag }
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

fn test_insert_basic() {
    var s: {u64}
    ck(s.insert(5), "insert into an empty set is new")
    ck(s.size() == 1 && s.contains(5), "one element")
    ck(!s.insert(5), "insert of a present element is not new")
    ck(s.size() == 1, "a repeated insert keeps the size")
    ck(s.insert(6) && s.insert(4) && s.insert(7), "more elements")
    ck(is_order(s, [5, 6, 4, 7]), "insertion order")
    ck(!s.insert(4) && is_order(s, [5, 6, 4, 7]), "a repeat keeps its first place")
    ck(s.insert(0), "zero is an ordinary element")
    ck(s.insert(18446744073709551615), "the largest key is an ordinary element")
    ck(s.contains(0) && s.contains(18446744073709551615), "extreme keys are found")
}

fn test_insert_range() {
    var s: {u64}
    var seen: u64 = 0
    for var i: u64 = 0; i < 100; i += 1 {
        if !s.insert(i % 37) { seen += 1 }
    }
    ck(s.size() == 37 && seen == 63, "inserting 100 values of 37 residues")
    var ok = true
    for var i: u64 = 0; i < 37; i += 1 {
        if !s.contains(i) { ok = false }
    }
    ck(ok && !s.contains(37), "every residue is present")
    ck(s.first()? && s.last()?, "first and last exist")
    var *f? = s.first()
    var *l? = s.last()
    ck(f? && l? && *f == 0 && *l == 36, "first and last in insertion order")
}

fn test_insert_many() {
    var s: {u64}
    var new_count: u64 = 0
    for var i: u64 = 0; i < 20000; i += 1 {
        if s.insert(i * 7919) { new_count += 1 }
    }
    ck(new_count == 20000 && s.size() == 20000, "twenty thousand inserts are all new")
    var bad: u64 = 0
    for var i: u64 = 0; i < 20000; i += 1 {
        if !s.contains(i * 7919) { bad += 1 }
        if s.insert(i * 7919) { bad += 1 }
    }
    ck(bad == 0 && s.size() == 20000, "every element found, no repeat accepted")
}

fn test_insert_strings() {
    var s: {string}
    ck(s.insert("alpha") && s.insert("beta"), "strings insert")
    ck(!s.insert("alpha"), "a repeated string is not new")
    ck(s.insert("") && s.contains(""), "the empty string is an element")
    ck(s.size() == 3, "three strings")
    var bigstr: string = ""
    for var i: u32 = 0; i < 200; i += 1 { bigstr += "xy" }
    var bigstr2 = bigstr.copy()
    ck(s.insert(bigstr) && !s.insert(bigstr2), "a 400-byte string")
    ck(s.contains("alpha") && s.contains("beta") && !s.contains("gamma"), "string lookups")
}

fn test_insert_keeps_stored() {
    var s: {Rec}
    ck(s.insert(Rec { id: 1, tag: 10 }), "record inserted")
    ck(!s.insert(Rec { id: 1, tag: 20 }), "an equal record is not new")
    var *p? = s.first()
    ck(p? && p->tag == 10, "insert keeps the stored record and drops the new one")
    ck(s.size() == 1, "one record")
}

fn test_replace() {
    var s: {Rec}
    var r0? = s.replace(Rec { id: 1, tag: 1 })
    ck(!r0? && s.size() == 1, "replace on an empty set inserts and returns null")
    var r1? = s.replace(Rec { id: 1, tag: 2 })
    ck(r1? && s.size() == 1, "replace of an equal record returns the old one")
    if r1? { ck(r1.id == 1 && r1.tag == 1, "the returned record is the old one") }
    var *p? = s.first()
    ck(p? && p->tag == 2, "the new record is stored")
    s.insert(Rec { id: 2, tag: 5 })
    s.insert(Rec { id: 3, tag: 6 })
    var r2? = s.replace(Rec { id: 2, tag: 50 })
    ck(r2? && r2.tag == 5, "replace of a middle record")
    var n: u64 = 0
    var tags: u64 = 0
    for const *x in s {
        n += 1
        tags = tags * 100 + x->tag
    }
    ck(n == 3 && tags == 2 * 10000 + 50 * 100 + 6, "replace keeps the place of the element")
    var r3? = s.replace(Rec { id: 9, tag: 9 })
    ck(!r3? && s.size() == 4 && s.contains(Rec { id: 9, tag: 0 }), "replace of a new record appends")
    var *l? = s.last()
    ck(l? && l->id == 9, "a new record goes last")
    var ints: {u64} = {1, 2, 3}
    var ri? = ints.replace(2)
    ck(ri? && ri == 2 && is_order(ints, [1, 2, 3]), "replace of an integer")
    var ss: {string} = {"a", "b"}
    var rs? = ss.replace("a")
    ck(rs? && rs == "a" && ss.size() == 2, "replace of a string")
    var rn? = ss.replace("c")
    ck(!rn? && ss.size() == 3, "replace of a new string")
}

fn test_extend_from() {
    var s: {u64} = {1}
    var more: [u64] = [2, 3, 4]
    s.extend_from(more)
    ck(is_order(s, [1, 2, 3, 4]), "extend_from appends")
    var rep: [u64] = [4, 1, 5, 5]
    s.extend_from(rep)
    ck(is_order(s, [1, 2, 3, 4, 5]), "extend_from skips what is present")
    var none: [u64]
    s.extend_from(none)
    ck(s.size() == 5, "extend_from of nothing")
    var e: {u64}
    e.extend_from(more)
    ck(e.size() == 3, "extend_from into an empty set")
    var big: [u64]
    for var i: u64 = 0; i < 5000; i += 1 { big.push(i) }
    e.extend_from(big)
    ck(e.size() == 5000, "extend_from of 5000")
    var w: {string} = {"a"}
    var ws: [string] = ["b", "a", "c"]
    w.extend_from(ws)
    ck(w.size() == 3 && ws.size() == 3, "extend_from of strings copies")
}

fn test_union_assign() {
    var a: {u64} = {1, 2, 3}
    var b: {u64} = {3, 4, 5, 1}
    a |= b
    ck(is_order(a, [1, 2, 3, 4, 5]), "|= appends what is missing in the order of the other")
    ck(is_order(b, [3, 4, 5, 1]), "|= leaves the other")
    var e: {u64}
    e |= b
    ck(is_order(e, [3, 4, 5, 1]), "|= into an empty set")
    a |= e
    ck(a.size() == 5, "|= of subset adds nothing")
    var z: {u64}
    a |= z
    ck(a.size() == 5, "|= of an empty set")
    a |= a
    ck(a.size() == 5, "|= of itself")
}

fn test_counted() {
    {
        var s: {Ctr}
        for var i: u64 = 0; i < 100; i += 1 { s.insert(Ctr(i, 0)) }
        ck(s.size() == 100 && live == 100, "hundred counted elements alive once each")
        var before = live
        for var i: u64 = 0; i < 100; i += 1 {
            if s.insert(Ctr(i, 1)) { errors += 1 }
        }
        ck(live == before, "a rejected element is destroyed")
        var all_old = true
        for const *x in s {
            if x->tag != 0 { all_old = false }
        }
        ck(all_old, "the stored elements are the first ones")
        var old? = s.replace(Ctr(50, 7))
        ck(old? && live == before + 1, "replace keeps the old element alive in its result")
        if old? { ck(old.tag == 0, "the replaced element is the old one") }
        old = null
        ck(live == before, "dropping the returned element destroys it")
        var *g? = s.get(Ctr(50, 0))
        ck(g? && g->tag == 7, "get finds the replacement")
        var rn? = s.replace(Ctr(500, 3))
        ck(!rn? && live == before + 1, "replace of a new element adds one")
        var t: {Ctr}
        t.insert(Ctr(1, 0))
        t |= s
        ck(t.size() == 101, "|= copies in the missing elements")
        ck(live == before + 1 + 101, "|= makes one copy per new element")
    }
    ck(live == 0, "nothing is left")
    ck(errors == 0, "no use after a move and no double destroy")
}

fn main() -> i32 {
    test_insert_basic()
    test_insert_range()
    test_insert_many()
    test_insert_strings()
    test_insert_keeps_stored()
    test_replace()
    test_extend_from()
    test_union_assign()
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
