// Set algebra on a HashSet: set_union, set_intersection, set_difference, set_xor, is_subset,
// is_superset, is_disjoint, `==`, and the operators `&=`, `-=`, `|=`, `^=`, on empty, one and many
// elements, with integers, strings and counted elements. The order of every result is the
// documented one: union is `self` then the rest of the other; intersection walks the smaller set
// (`self` when the sizes are equal); difference is `self`'s order; xor is the survivors of `self`
// then those of the other (the doc comments of each member). Equality ignores order (`==`'s doc
// comment: "The same elements; order does not take part").
//
// Cases from libc++ test/std/containers/unord/unord.set/ (eq, eq.different_hash)
// Cases from Rust library/std/src/collections/hash/set/tests.rs (test_disjoint,
// test_subset_and_superset, test_intersection, test_difference, test_symmetric_difference,
// test_union, test_eq)
// Cases from Rust hashbrown src/set.rs tests (test_sub_assign)
//
// Not ported, with the reason: the binary operators `&`, `|`, `-`, `^` that build a new set (the
// type has only the assigning forms and the lazy iterators: listed as an API gap).

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

extend Ctr impl Copyable {
    fn copy(const self) -> Ctr {
        return Ctr(self.v)
    }
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

fn is_order(const s: {u64}, const want: [u64]) -> bool {
    return same(order(s), want)
}

fn of(const items: [u64]) -> {u64} {
    var s: {u64}
    for x in items { s.insert(x) }
    return s
}

fn range(lo: u64, hi: u64) -> {u64} {
    var s: {u64}
    for var i = lo; i < hi; i += 1 { s.insert(i) }
    return s
}

fn uni(const a: {u64}, const b: {u64}) -> [u64] {
    var r: [u64]
    for x in a.set_union(b) { r.push(*x) }
    return r
}

fn inter(const a: {u64}, const b: {u64}) -> [u64] {
    var r: [u64]
    for x in a.set_intersection(b) { r.push(*x) }
    return r
}

fn diff(const a: {u64}, const b: {u64}) -> [u64] {
    var r: [u64]
    for x in a.set_difference(b) { r.push(*x) }
    return r
}

fn symdiff(const a: {u64}, const b: {u64}) -> [u64] {
    var r: [u64]
    for x in a.set_xor(b) { r.push(*x) }
    return r
}

fn test_union() {
    var a: {u64}
    var b: {u64}
    ck(uni(a, b).size() == 0 && uni(b, a).size() == 0, "union of two empty sets")
    a = of([1, 3, 11, 16, 19, 24])
    b = of([902, 1, 5, 9, 13, 19])
    ck(same(uni(a, b), [1, 3, 11, 16, 19, 24, 902, 5, 9, 13]), "union is self, then the rest of the other")
    ck(same(uni(b, a), [902, 1, 5, 9, 13, 19, 3, 11, 16, 24]), "union the other way round")
    a.insert(9)
    a.insert(5)
    ck(uni(a, b).size() == 10 && uni(b, a).size() == 10, "union count with the first set the bigger")
    ck(same(uni(a, a), order(a)), "union of a set with itself")
    ck(same(uni(a, range(100, 100)), order(a)), "union with an empty set")
    ck(same(uni(range(100, 100), b), order(b)), "union of an empty set with another")
}

fn test_intersection() {
    var a: {u64}
    var b: {u64}
    ck(inter(a, b).size() == 0, "intersection of two empty sets")
    a = of([11, 1, 3, 77, 103, 5, 9999])
    b = of([2, 3, 5, 8888, 7777, 77, 11])
    ck(same(inter(a, b), [11, 3, 77, 5]), "intersection of equal sizes walks self")
    ck(same(inter(b, a), [3, 5, 77, 11]), "intersection the other way round")
    a.insert(9)
    ck(same(inter(a, b), [3, 5, 77, 11]), "intersection walks the smaller set (the other)")
    ck(same(inter(b, a), [3, 5, 77, 11]), "intersection with the first the smaller")
    ck(inter(a, range(500, 510)).size() == 0, "disjoint sets intersect in nothing")
    ck(same(inter(a, a), order(a)), "intersection with itself")
    ck(inter(a, range(7, 7)).size() == 0, "intersection with an empty set")
}

fn test_difference() {
    var a = of([1, 3, 5, 9, 11])
    var b = of([3, 9])
    ck(same(diff(a, b), [1, 5, 11]), "difference keeps the order of self")
    ck(same(diff(b, a), []), "difference of a subset is empty")
    ck(same(diff(a, range(0, 0)), [1, 3, 5, 9, 11]), "difference with an empty set")
    ck(diff(range(0, 0), a).size() == 0, "difference of an empty set")
    ck(diff(a, a).size() == 0, "difference with itself")
}

fn test_symmetric_difference() {
    var a = of([1, 3, 5, 9, 11])
    var b = of([902, 3, 9, 14, 22])
    ck(same(symdiff(a, b), [1, 5, 11, 902, 14, 22]), "xor is the survivors of self, then the other's")
    ck(same(symdiff(b, a), [902, 14, 22, 1, 5, 11]), "xor the other way round")
    ck(symdiff(a, a).size() == 0, "xor with itself")
    ck(same(symdiff(a, range(0, 0)), order(a)), "xor with an empty set")
    ck(same(symdiff(range(0, 0), a), order(a)), "xor of an empty set")
}

fn test_subset_superset_disjoint() {
    var xs: {u64}
    var ys: {u64}
    ck(xs.is_disjoint(ys) && ys.is_disjoint(xs), "two empty sets are disjoint")
    xs.insert(5)
    ys.insert(11)
    ck(xs.is_disjoint(ys) && ys.is_disjoint(xs), "single distinct elements are disjoint")
    xs.insert(7)
    xs.insert(19)
    xs.insert(4)
    ys.insert(2)
    ys.insert(911)
    ck(xs.is_disjoint(ys) && ys.is_disjoint(xs), "bigger disjoint sets")
    ys.insert(7)
    ck(!xs.is_disjoint(ys) && !ys.is_disjoint(xs), "one shared element breaks disjointness")

    var a = of([0, 5, 11, 7])
    var b = of([0, 7, 19, 250, 11, 200])
    ck(!a.is_subset(b) && !a.is_superset(b) && !b.is_subset(a) && !b.is_superset(a), "neither contains the other")
    b.insert(5)
    ck(a.is_subset(b) && !a.is_superset(b) && !b.is_subset(a) && b.is_superset(a), "a proper subset")
    ck(a.is_subset(a) && a.is_superset(a), "a set is a subset and a superset of itself")
    var e: {u64}
    ck(e.is_subset(a) && a.is_superset(e) && !a.is_subset(e) && e.is_subset(e), "the empty set is a subset of every set")
    ck(e.is_disjoint(a) && a.is_disjoint(e), "the empty set is disjoint from every set")
    ck(!a.is_disjoint(a), "a non-empty set is not disjoint from itself")
}

fn test_equality() {
    var c1 = of([10, 20, 30, 40, 50, 60, 70, 80])
    var c2: {u64}
    ck(!(c1 == c2) && c1 != c2, "a set and an empty set differ")
    var c3 = c1.copy()
    ck(c1 == c3 && !(c1 != c3), "a copy is equal")
    c3.reserve(1000)
    ck(c1 == c3, "capacity takes no part in equality")
    c3.insert(90)
    ck(!(c1 == c3) && c1 != c3, "an extra element makes them differ")
    c1.insert(90)
    ck(c1 == c3 && !(c1 != c3), "equal again")
    var rev = of([80, 70, 60, 50, 40, 30, 20, 10, 90])
    ck(c1 == rev, "equality ignores order")
    var same_size = of([10, 20, 30, 40, 50, 60, 70, 80, 91])
    ck(c1 != same_size, "same size, one element differs")
    ck(c2 == c2 && c2 == range(0, 0), "empty sets are equal")
    var s1: {string} = {"a", "b", "c"}
    var s2: {string} = {"c", "a", "b"}
    var s3: {string} = {"a", "b", "d"}
    ck(s1 == s2 && s1 != s3, "string sets")
    var e1: {u64} = {1, 2, 3}
    var e2: {u64} = {1, 2}
    ck(e1 != e2, "a set with a missing element differs")
    e2.insert(3)
    ck(e1 == e2, "the set with the missing element added is equal")
}

fn test_assign_operators() {
    var a = range(0, 10)
    var b = range(5, 15)
    a &= b
    ck(is_order(a, [5, 6, 7, 8, 9]), "&= keeps what both hold, in self's order")
    a = range(0, 10)
    a -= b
    ck(is_order(a, [0, 1, 2, 3, 4]), "-= removes what the other holds")
    a = range(0, 10)
    a |= b
    ck(is_order(a, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]), "|= appends what is missing")
    a = range(0, 10)
    a ^= b
    ck(is_order(a, [0, 1, 2, 3, 4, 10, 11, 12, 13, 14]), "^= keeps the survivors, then the other's new elements")
    var e: {u64}
    a &= e
    ck(a.is_empty(), "&= with an empty set empties")
    a = range(0, 4)
    a -= e
    ck(a.size() == 4, "-= with an empty set")
    a ^= e
    ck(a.size() == 4, "^= with an empty set")
    e ^= a
    ck(is_order(e, [0, 1, 2, 3]), "^= into an empty set copies")
    var big = range(0, 5000)
    big &= range(2500, 7500)
    ck(big.size() == 2500 && big.contains(2500) && !big.contains(2499), "&= over 5000 elements")
    big -= range(2500, 5000)
    ck(big.is_empty(), "-= of everything")
    var s1 = range(0, 50)
    s1 &= s1
    ck(s1.size() == 50, "s &= s")
    s1 |= s1
    ck(s1.size() == 50, "s |= s")
    s1 -= s1
    ck(s1.is_empty(), "s -= s")
    var s2 = range(0, 50)
    s2 ^= s2
    ck(s2.is_empty(), "s ^= s")
}

fn test_strings() {
    var a: {string} = {"a", "b", "c", "d"}
    var b: {string} = {"c", "d", "e"}
    var u: [string]
    for x in a.set_union(b) { u.push(x->copy()) }
    ck(u.size() == 5 && u[4] == "e", "union of strings")
    var n = 0
    for x in a.set_intersection(b) { n += 1 }
    ck(n == 2, "intersection of strings")
    var d = 0
    for x in a.set_difference(b) { d += 1 }
    ck(d == 2, "difference of strings")
    var xo = 0
    for x in a.set_xor(b) { xo += 1 }
    ck(xo == 3, "xor of strings")
    var c = a.copy()
    c ^= b
    ck(c.size() == 3 && c.contains("a") && c.contains("b") && c.contains("e"), "^= of strings")
    c |= a
    ck(c.size() == 5, "|= of strings")
    c &= b
    ck(c.size() == 3 && c.contains("c") && c.contains("d") && c.contains("e"), "&= of strings")
    ck(a.is_subset(a) && !a.is_subset(b) && !a.is_disjoint(b), "relations of strings")
}

fn test_counted() {
    {
        var a: {Ctr}
        var b: {Ctr}
        for var i: u64 = 0; i < 10; i += 1 { a.insert(Ctr(i)) }
        for var i: u64 = 5; i < 15; i += 1 { b.insert(Ctr(i)) }
        ck(live == 20, "twenty alive")
        var n: u64 = 0
        for x in a.set_union(b) { n += 1 }
        for x in a.set_intersection(b) { n += 1 }
        for x in a.set_difference(b) { n += 1 }
        for x in a.set_xor(b) { n += 1 }
        ck(n == 15 + 5 + 5 + 10 && live == 20, "the iterators build no elements")
        var c = a.copy()
        c &= b
        ck(c.size() == 5 && live == 25, "&= destroys what it drops")
        c -= a
        ck(c.is_empty() && live == 20, "-= destroys what it drops")
        var d = a.copy()
        d |= b
        ck(d.size() == 15 && live == 35, "|= copies each missing element once")
        var e = a.copy()
        e ^= b
        ck(e.size() == 10 && live == 35 + 10, "^= keeps ten, destroys five, copies five")
        e -= e
        ck(live == 35, "s -= s destroys all")
    }
    ck(live == 0, "nothing is left")
    ck(errors == 0, "no use after a move and no double destroy")
}

fn main() -> i32 {
    test_union()
    test_intersection()
    test_difference()
    test_symmetric_difference()
    test_subset_superset_disjoint()
    test_equality()
    test_assign_operators()
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
