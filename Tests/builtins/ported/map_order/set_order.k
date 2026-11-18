// Where an element lands in a HashSet<T> and what every operation does to
// the order: insert (a present element does not move), replace (the new
// value takes the place of the equal one), the removals (swap_remove and
// take move the last element into the gap, shift_remove keeps the order, pop
// takes the last), retain, clear then reuse, a literal, from_slice,
// extend_from and collect; the in-place algebra (|=, ^=, &=, -=) and the
// lazy algebra (set_union, set_intersection, set_difference, set_xor) with
// the order each gives; and equality, which ignores order. Each removal
// sequence is checked against a vector that removes by the same rule.
//
// differs from C++ and Rust: iteration order is defined (hash_set.k, the doc
// comment on HashSet; "The same elements; order does not take part" on op
// ==; "The elements of `self`, then those of `o` not in `self`" on
// set_union; "in the order of the smaller set (of `self` when the sizes are
// equal)" on set_intersection).
//
// Cases from indexmap src/set/tests.rs (insert, insert_order, insert_dup, replace, replace_order, replace_dup, replace_change, remove, swap_remove_index, partial_eq_and_eq, extend, ops, from_array, take, swap_take, shift_take, shift_remove_full, retain, first, last)
// Cases from indexmap tests/quick.rs (insertion_order, pop, retain_ordered, shift_remove, set_swap_indices)

import std::iter::*
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

/// The elements in order, read through the for loop and items(); the text
/// says so when they disagree.
fn xs(const s: {u64}) -> string {
    var a = ""
    var b = ""
    for x in s { a += f"{x} " }
    for x in s.items() { b += f"{x} " }
    if a != b { return f"MISMATCH loop[{a}] items[{b}]" }
    return a
}

fn show(const v: [u64]) -> string {
    var a = ""
    for x in v { a += f"{x} " }
    return a
}

fn ends(const s: {u64}) -> bool {
    if s.size() == 0 { return !s.first()? && !s.last()? }
    var f? = s.first()
    var l? = s.last()
    return f? && l? && *f == s.items()[0] && *l == s.items()[s.size() - 1]
}

fn of(const v: [u64]) -> {u64} {
    var s: {u64}
    for x in v { s.insert(x) }
    return s
}

struct TKey {
    pub var id: u64
    pub var tag: u64
}

extend TKey impl Hash {
    fn hash(const self, @inout h: Hasher) { h.write_u64(self.id) }
    fn op == (const self, const o: TKey) -> bool { return self.id == o.id }
}

extend TKey impl Copyable {
    fn copy(const self) -> TKey { return TKey { id: self.id, tag: self.tag } }
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

extend Obj impl Hash {
    fn hash(const self, @inout h: Hasher) { h.write_u64(self.v) }
    fn op == (const self, const o: Obj) -> bool { return self.v == o.v }
}

fn keep_odd(x: *const u64) -> bool { return *x % 2 == 1 }
fn keep_all(x: *const u64) -> bool { return true }
fn drop_all(x: *const u64) -> bool { return false }
fn keep_obj_odd(x: *const Obj) -> bool { return x->v % 2 == 1 }

var seen: [u64]

fn note_odd(x: *const u64) -> bool {
    seen.push(*x)
    return *x % 2 == 1
}

/// The yielded elements of a lazy set operation, as text.
fn union_of(const a: {u64}, const b: {u64}) -> string {
    var t = ""
    for x in a.set_union(b) { t += f"{*x} " }
    return t
}

fn inter_of(const a: {u64}, const b: {u64}) -> string {
    var t = ""
    for x in a.set_intersection(b) { t += f"{*x} " }
    return t
}

fn diff_of(const a: {u64}, const b: {u64}) -> string {
    var t = ""
    for x in a.set_difference(b) { t += f"{*x} " }
    return t
}

fn xor_of(const a: {u64}, const b: {u64}) -> string {
    var t = ""
    for x in a.set_xor(b) { t += f"{*x} " }
    return t
}

fn test_insert_order() {
    var insert: [u64] = [0, 4, 2, 12, 8, 7, 11, 5, 3, 17, 19, 22, 23]
    var s: {u64}
    ck(xs(s) == "" && ends(s), "empty set")
    var want = ""
    var all_new = true
    for var i: usize = 0; i < insert.size(); i += 1 {
        if !s.insert(insert[i]) { all_new = false }
        want += f"{insert[i]} "
        if !ends(s) { all_new = false }
    }
    ck(all_new && xs(s) == want, "insert: a new element goes last and returns true")
    ck(!s.insert(4) && !s.insert(0) && !s.insert(23), "insert: a present element returns false")
    ck(xs(s) == want, "insert: a present element does not move, at the front, the middle or the end")
    var f? = s.first()
    var l? = s.last()
    ck(f? && *f == 0 && l? && *l == 23 && s.size() == 13, "first and last")
    var good = true
    for var i: usize = 0; i < insert.size(); i += 1 {
        if s.items()[i] != insert[i] { good = false }
    }
    ck(good, "items()[i] is the i-th inserted element")
}

fn test_replace_order() {
    var s: {TKey}
    ck(s.replace(TKey { id: 1, tag: 10 }) == null, "replace of a new element returns null")
    s.replace(TKey { id: 2, tag: 20 })
    s.replace(TKey { id: 3, tag: 30 })
    var old? = s.replace(TKey { id: 2, tag: 21 })
    ck(old? && old.id == 2 && old.tag == 20, "replace of a present element returns the old one")
    var order = ""
    for const *e in s.items() { order += f"{e->id}.{e->tag} " }
    ck(order == "1.10 2.21 3.30 ", "replace: the new value sits in the old one's place")
    var kept = s.insert(TKey { id: 3, tag: 31 })
    order = ""
    for const *e in s.items() { order += f"{e->id}.{e->tag} " }
    ck(!kept && order == "1.10 2.21 3.30 ", "insert of an equal element keeps the stored one")
    old = s.replace(TKey { id: 1, tag: 12 })
    old = s.replace(TKey { id: 3, tag: 32 })
    order = ""
    for const *e in s.items() { order += f"{e->id}.{e->tag} " }
    ck(order == "1.12 2.21 3.32 ", "replace the first and the last: places kept")
    s.replace(TKey { id: 9, tag: 90 })
    ck(s.items()[3].id == 9 && s.size() == 4, "replace of a new element appends")
}

fn test_removal_orders() {
    var s = of([10, 20, 30, 40, 50])
    ck(s.swap_remove(20) && xs(s) == "10 50 30 40 ", "swap_remove in the middle: the last takes the place")
    ck(s.swap_remove(10) && xs(s) == "40 50 30 ", "swap_remove of the first")
    ck(s.swap_remove(30) && xs(s) == "40 50 " && ends(s), "swap_remove of the last")
    ck(!s.swap_remove(99) && xs(s) == "40 50 ", "swap_remove of a missing element: false")
    var t = of([10, 20, 30, 40, 50])
    ck(t.shift_remove(20) && xs(t) == "10 30 40 50 ", "shift_remove in the middle: order kept")
    ck(t.shift_remove(10) && xs(t) == "30 40 50 ", "shift_remove of the first")
    ck(t.shift_remove(50) && xs(t) == "30 40 " && ends(t), "shift_remove of the last")
    ck(!t.shift_remove(99) && xs(t) == "30 40 ", "shift_remove of a missing element: false")
    var u = of([1, 2, 3, 4])
    var got? = u.take(2)
    ck(got? && got == 2 && xs(u) == "1 4 3 ", "take: the element, and the last takes its place")
    got = u.take(2)
    ck(!got? && xs(u) == "1 4 3 ", "take of a missing element: null")
    var p? = u.pop()
    ck(p? && p == 3 && xs(u) == "1 4 ", "pop: the last element")
    p = u.pop()
    p = u.pop()
    ck(p? && p == 1 && u.is_empty() && ends(u), "pop down to empty")
    p = u.pop()
    ck(!p? && u.is_empty(), "pop on an empty set")
}

fn test_removals_against_vector() {
    var insert: [u64] = [0, 4, 2, 12, 8, 7, 11, 5, 3, 17, 19, 22, 23]
    var seq: [usize] = [3, 3, 10, 4, 5, 4, 3, 0, 1]
    for var form: u64 = 0; form < 3; form += 1 {
        var s = of(insert)
        var model = [u64]::from_slice(insert)
        var good = true
        for var i: usize = 0; i < seq.size(); i += 1 {
            var pos = seq[i]
            if form == 1 { pos = (seq[i] * 5) % model.size() }
            if form == 2 { pos = model.size() - 1 - (seq[i] % model.size()) }
            if pos >= model.size() { pos = model.size() - 1 }
            var gone: u64
            if form == 1 { gone = model.remove(pos) } else { gone = model.swap_remove(pos) }
            if form == 0 {
                if !s.swap_remove(gone) { good = false }
            } else if form == 1 {
                if !s.shift_remove(gone) { good = false }
            } else {
                var t? = s.take(gone)
                if !t? || t != gone { good = false }
            }
            if xs(s) != show(model) || !ends(s) { good = false; break }
        }
        ck(good && s.size() == model.size(), f"removal sequence, form {form}: order equals the vector after every step")
    }
}

fn test_retain_order() {
    var s = of([1, 2, 3, 4, 5, 6, 7, 8, 9])
    seen = []
    s.retain(note_odd)
    ck(show(seen) == "1 2 3 4 5 6 7 8 9 " && xs(s) == "1 3 5 7 9 " && ends(s), "retain: each element shown once, front to back; survivors in order")
    s.retain(keep_all)
    ck(xs(s) == "1 3 5 7 9 ", "retain that keeps everything")
    s.retain(keep_odd)
    s.insert(4)
    s.insert(5)
    s.insert(2)
    ck(xs(s) == "1 3 5 7 9 4 2 ", "retain then insert")
    s.retain(drop_all)
    ck(xs(s) == "" && ends(s) && s.is_empty(), "retain that drops everything")
    s.retain(keep_odd)
    ck(s.is_empty(), "retain on an empty set")
}

fn test_clear_then_reuse() {
    var s = of([5, 4, 3])
    var cap = s.capacity()
    s.clear()
    ck(xs(s) == "" && ends(s) && s.capacity() == cap, "clear: empty, capacity stays")
    s.insert(3)
    s.insert(4)
    s.insert(5)
    ck(xs(s) == "3 4 5 ", "clear then reuse: the order follows the new inserts")
    s.clear()
    s.clear()
    ck(s.is_empty(), "clear twice")
}

fn test_construction_orders() {
    var lit: {u64} = {3, 1, 3, 2, 1}
    ck(xs(lit) == "3 1 2 ", "literal: a repeated element keeps its first place")
    var items: [u64] = [7, 5, 7, 6, 5, 4]
    var fs = {u64}::from_slice(items)
    ck(xs(fs) == "7 5 6 4 ", "from_slice: first place")
    var ext = of([5, 9])
    ext.extend_from(items)
    ck(xs(ext) == "5 9 7 6 4 ", "extend_from: existing elements keep their place, new ones append in order")
    var none: [u64]
    ext.extend_from(none)
    ck(xs(ext) == "5 9 7 6 4 ", "extend_from: empty slice")
    var col = iter(items.iter()).copied().collect<{u64}>()
    ck(xs(col) == "7 5 6 4 ", "collect: first place")
    var one: {u64} = {8}
    ck(xs(one) == "8 " && ends(one), "literal of one element")
}

fn test_lazy_algebra_orders() {
    var a = of([5, 1, 9, 3])
    var b = of([3, 8, 5, 2])
    ck(union_of(a, b) == "5 1 9 3 8 2 ", "set_union: self's elements, then other's new ones in other's order")
    ck(union_of(b, a) == "3 8 5 2 1 9 ", "set_union the other way: the order flips")
    ck(inter_of(a, b) == "5 3 ", "set_intersection, equal sizes: in self's order")
    ck(inter_of(b, a) == "3 5 ", "set_intersection, equal sizes, the other way")
    ck(diff_of(a, b) == "1 9 " && diff_of(b, a) == "8 2 ", "set_difference: self's order")
    ck(xor_of(a, b) == "1 9 8 2 " && xor_of(b, a) == "8 2 1 9 ", "set_xor: self's survivors, then other's")
    // The smaller set is walked for the intersection.
    var big = of([50, 40, 30, 20, 10, 60])
    var small = of([10, 30, 70])
    ck(inter_of(big, small) == "10 30 ", "set_intersection with a smaller other: in the smaller set's order")
    ck(inter_of(small, big) == "10 30 ", "set_intersection with a bigger other: in self's (the smaller) order")
    var e: {u64}
    ck(union_of(e, a) == "5 1 9 3 " && union_of(a, e) == "5 1 9 3 ", "set_union with an empty set")
    ck(inter_of(e, a) == "" && inter_of(a, e) == "", "set_intersection with an empty set")
    ck(diff_of(a, e) == "5 1 9 3 " && diff_of(e, a) == "", "set_difference with an empty set")
    ck(xor_of(a, e) == "5 1 9 3 " && xor_of(e, a) == "5 1 9 3 ", "set_xor with an empty set")
    ck(union_of(a, a) == "5 1 9 3 " && inter_of(a, a) == "5 1 9 3 " && diff_of(a, a) == "" && xor_of(a, a) == "", "the algebra of a set with itself")
    ck(xs(a) == "5 1 9 3 " && xs(b) == "3 8 5 2 ", "the lazy operations change neither operand")
}

fn test_in_place_algebra_orders() {
    var a = of([5, 1, 9, 3])
    var b = of([3, 8, 5, 2])
    a |= b
    ck(xs(a) == "5 1 9 3 8 2 ", "|=: other's new elements append in other's order")
    ck(xs(b) == "3 8 5 2 ", "|=: other is unchanged")

    var c = of([5, 1, 9, 3])
    c &= b
    ck(xs(c) == "5 3 ", "&=: the survivors keep self's order")

    var d = of([5, 1, 9, 3])
    d -= b
    ck(xs(d) == "1 9 ", "-=: the rest keep self's order")

    var e = of([5, 1, 9, 3])
    e ^= b
    ck(xs(e) == "1 9 8 2 ", "^=: self's survivors keep their order, then other's new elements in other's order")

    var f = of([5, 1, 9, 3])
    f |= f
    f &= f
    ck(xs(f) == "5 1 9 3 ", "|= and &= with itself")
    f ^= f
    ck(xs(f) == "" && ends(f), "^= with itself empties")
    var g = of([5, 1])
    g -= g
    ck(g.is_empty(), "-= with itself empties")
    var h = of([4, 2, 6])
    var none: {u64}
    h |= none
    h &= h
    ck(xs(h) == "4 2 6 ", "|= with an empty set")
    h &= none
    ck(xs(h) == "" && ends(h), "&= with an empty set")
    var i = of([4, 2, 6])
    i ^= none
    ck(xs(i) == "4 2 6 ", "^= with an empty set")
    none ^= i
    ck(xs(none) == "4 2 6 ", "^= into an empty set takes other's order")
    var j: {u64}
    j |= of([3, 1, 2])
    ck(xs(j) == "3 1 2 ", "|= into an empty set takes other's order")
}

fn test_equality_ignores_order() {
    var a = of([1, 2, 3, 4])
    var b = of([4, 3, 2, 1])
    var c = of([1, 2, 3])
    var d = of([1, 2, 3, 5])
    ck(a == b && b == a, "== : the same elements in another order are equal")
    ck(!(a != b), "!= : the same elements in another order are not different")
    ck(a != c && c != a, "== : a subset is not equal")
    ck(a != d && d != a, "== : the same size with one element different")
    var e1: {u64}
    var e2: {u64}
    ck(e1 == e2 && e1 != a && a != e1, "== : empty sets")
    ck(a == a, "== : a set with itself")
    var x = of([9, 8, 7])
    x.swap_remove(9)
    var y = of([8, 7])
    var z = of([7, 8])
    ck(x == y && y == z && x == z, "== : equal sets with different histories")
    var s1 = of([1, 2, 3])
    var s2 = s1.copy()
    s2.shift_remove(1)
    s2.insert(1)
    ck(xs(s1) == "1 2 3 " && xs(s2) == "2 3 1 " && s1 == s2, "== : a copy with one element moved to the end is equal")
    ck(a.is_subset(b) && b.is_subset(a) && a.is_superset(c) && c.is_subset(a) && !a.is_subset(c), "subset and superset ignore order")
    ck(!a.is_disjoint(c) && c.is_disjoint(of([8, 9])), "is_disjoint ignores order")
}

fn test_strings() {
    var s: {string}
    s.insert("pear".copy())
    s.insert("apple".copy())
    s.insert("fig".copy())
    s.insert("apple".copy())
    var order = ""
    for const *x in s { order += f"{*x} " }
    ck(order == "pear apple fig ", "strings: insertion order, a repeat does not move")
    s.shift_remove("pear")
    order = ""
    for const *x in s { order += f"{*x} " }
    ck(order == "apple fig ", "strings: shift_remove")
    var t? = s.take("apple")
    ck(t? && t == "apple" && s.items()[0] == "fig", "strings: take")
    var p? = s.pop()
    ck(p? && p == "fig" && s.is_empty(), "strings: pop")
    var a: {string} = {"x", "y", "z"}
    var b: {string} = {"z", "w", "x"}
    var u = ""
    for const *e in a.set_union(b) { u += f"{*e} " }
    ck(u == "x y z w ", "strings: set_union order")
    var o = a.copy()
    o ^= b
    order = ""
    for const *x in o { order += f"{*x} " }
    ck(order == "y w ", "strings: ^= order")
    ck(a == a.copy() && a != b, "strings: equality")
}

fn test_counted() {
    live = 0
    errors = 0
    {
        var s: {Obj}
        for var i: u64 = 0; i < 20; i += 1 { s.insert(Obj(i * 3 % 20)) }
        ck(live == 20, "counted: one live object per element")
        var fresh = s.insert(Obj(0))
        ck(!fresh && live == 20, "counted: the rejected element is destroyed")
        var old? = s.replace(Obj(3))
        ck(old? && old.v == 3 && live == 21, "counted: replace hands the old element back")
        old = null
        ck(live == 20, "counted: the handed-back element dies when dropped")
        var order = ""
        for const *e in s.items() { order += f"{e->v} " }
        ck(order == "0 3 6 9 12 15 18 1 4 7 10 13 16 19 2 5 8 11 14 17 ", "counted: order")
        var t? = s.take(Obj(0))
        ck(t? && t.v == 0 && s.items()[0].v == 17 && live == 20, "counted: take, the last moves in")
        t = null
        s.shift_remove(Obj(3))
        ck(s.items()[0].v == 17 && s.items()[1].v == 6 && live == 18, "counted: shift_remove keeps the order")
        s.retain(keep_obj_odd)
        ck(live == s.size() as i64, "counted: retain destroys the dropped elements")
        var p? = s.pop()
        p = null
        s.clear()
        ck(live == 0, "counted: clear")
    }
    ck(live == 0 && errors == 0, "counted: nothing leaked, nothing destroyed twice")
}

fn main() -> i32 {
    test_insert_order()
    test_replace_order()
    test_removal_orders()
    test_removals_against_vector()
    test_retain_order()
    test_clear_then_reuse()
    test_construction_orders()
    test_lazy_algebra_orders()
    test_in_place_algebra_orders()
    test_equality_ignores_order()
    test_strings()
    test_counted()
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
