// Construction of a HashSet: default, with_capacity, literal, from_slice, from_iter, copy, move
// and move assignment (the swap idiom), on empty, one and many elements, for integer, string
// and move-only counted elements. A repeated element keeps its first place.
//
// Cases from libc++ test/std/containers/unord/unord.set/unord.set.cnstr/
// Cases from libc++ test/std/containers/unord/unord.set/unord.set.swap/
// Cases from Rust library/std/src/collections/hash/set/tests.rs
//
// Not ported, with the reason: allocator, hasher and key_eq constructor overloads, noexcept and
// compile-fail checks, deduction guides (a Kairo set has one hasher, no allocator argument), load
// factor and bucket queries (the table has no buckets API).

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

/// Move-only, counted; a use after a move or a second destroy bumps `errors`.
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
        if self.state != 1 { errors += 1 }
        h.write_u64(self.v)
    }

    fn op == (const self, const o: Ctr) -> bool {
        if self.state != 1 || o.state != 1 { errors += 1 }
        return self.v == o.v
    }
}

extend Ctr impl Copyable {
    fn copy(const self) -> Ctr {
        return Ctr(self.v)
    }
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

fn range(lo: u64, hi: u64) -> {u64} {
    var s: {u64}
    for var i = lo; i < hi; i += 1 { s.insert(i) }
    return s
}

fn test_default() {
    var s: {u64}
    ck(s.size() == 0 && s.is_empty() && s.capacity() == 0, "default set is empty with no storage")
    ck(!s.contains(0) && !s.first()? && !s.last()?, "default set holds nothing")
    var d = HashSet<u64>()
    ck(d.size() == 0 && d.capacity() == 0, "HashSet() is empty with no storage")
    var m = HashSet<u64>::make_default()
    ck(m.is_empty(), "Default makes an empty set")
    var ss: {string}
    ck(ss.is_empty() && ss.capacity() == 0, "default set of string")
}

fn test_zero_capacities() {
    var a = HashSet<u64>::with_capacity(0)
    ck(a.capacity() == 0, "with_capacity(0) takes no storage")
    var b: {u64}
    b.reserve(0)
    ck(b.capacity() == 0, "reserve(0) takes no storage")
    var c: {u64}
    c.insert(1)
    c.insert(2)
    c.swap_remove(1)
    c.swap_remove(2)
    c.shrink_to_fit()
    ck(c.capacity() == 0, "an emptied set shrinks to no storage")
}

fn test_with_capacity() {
    var s = HashSet<u64>::with_capacity(100)
    ck(s.capacity() >= 100 && s.size() == 0 && s.is_empty(), "with_capacity(100)")
    var cap = s.capacity()
    for var i: u64 = 0; i < 100; i += 1 { s.insert(i) }
    ck(s.capacity() == cap && s.size() == 100, "no growth within the reserved capacity")
    var one = HashSet<u64>::with_capacity(1)
    ck(one.capacity() >= 1, "with_capacity(1)")
    var st = HashSet<string>::with_capacity(10)
    ck(st.capacity() >= 10 && st.is_empty(), "with_capacity of string")
}

fn test_literal() {
    var e: {u64} = {}
    ck(e.is_empty(), "empty literal")
    var one: {u64} = {7}
    ck(one.size() == 1 && one.contains(7), "one-element literal")
    var lit: {u64} = {3, 1, 3, 2, 1}
    ck(is_order(lit, [3, 1, 2]), "a literal keeps the first place of a repeated element")
    var words: {string} = {"alpha", "beta", "alpha", "gamma"}
    ck(words.size() == 3 && words.contains("alpha") && words.contains("gamma"), "string literal drops the repeat")
    var big: {u64} = {10, 20, 30, 40, 50, 60, 70, 80}
    ck(big.size() == 8 && is_order(big, [10, 20, 30, 40, 50, 60, 70, 80]), "eight-element literal in written order")
}

fn test_from_slice() {
    var none: [u64]
    var a = HashSet<u64>::from_slice(none)
    ck(a.is_empty(), "from_slice of nothing")
    var items: [u64] = [1, 2, 3, 4, 1, 2]
    var b = HashSet<u64>::from_slice(items)
    ck(is_order(b, [1, 2, 3, 4]), "from_slice drops repeats, keeps order")
    ck(items.size() == 6, "from_slice leaves the source alone")
    var ws: [string] = ["x", "y", "x"]
    var c = HashSet<string>::from_slice(ws)
    ck(c.size() == 2 && c.contains("x") && c.contains("y"), "from_slice of string")
    ck(ws.size() == 3 && ws[0] == "x", "from_slice of string leaves the source alone")
}

fn test_from_iter() {
    var a = HashSet<u64>::from_iter(Upto(0), 0)
    ck(a.is_empty(), "from_iter of an empty range")
    var b = HashSet<u64>::from_iter(Upto(1), 0)
    ck(b.size() == 1 && b.contains(0), "from_iter of one")
    var c = HashSet<u64>::from_iter(Upto(500), 500)
    ck(c.size() == 500 && c.capacity() >= 500, "from_iter reserves the hint")
    var bad: u64 = 0
    for var i: u64 = 0; i < 500; i += 1 {
        if !c.contains(i) { bad += 1 }
    }
    ck(bad == 0 && c.size() == 500, "from_iter holds every element")
    var d = HashSet<u64>::from_iter(Upto(300), 0)
    ck(d.size() == 300 && is_order(d, order(d)), "from_iter with no hint")
}

fn test_copy() {
    var e: {u64}
    var ec = e.copy()
    ck(ec.is_empty() && ec == e, "copy of an empty set")
    var one: {u64} = {9}
    var oc = one.copy()
    ck(oc.size() == 1 && oc.contains(9) && oc == one, "copy of one")
    var m = range(0, 1000)
    var c = m.copy()
    ck(c == m && is_order(c, order(m)) && c.size() == 1000, "copy is equal and in the same order")
    c.insert(5000)
    c.swap_remove(3)
    ck(m.size() == 1000 && m.contains(3) && !m.contains(5000), "a change to the copy leaves the original")
    m.clear()
    ck(c.size() == 1000 && c.contains(999), "clearing the original leaves the copy")
    var strs: {string} = {"one", "two", "three"}
    var sc = strs.copy()
    strs.clear()
    ck(sc.size() == 3 && sc.contains("two") && sc.contains("three"), "copy of strings is deep")
}

fn test_move() {
    var a = range(0, 100)
    var b = move(a)
    ck(b.size() == 100 && b.contains(99), "move construction keeps the elements")
    var c: {u64} = {1, 2}
    c = move(b)
    ck(c.size() == 100 && is_order(c, order(c)) && c.contains(0), "move assignment replaces the elements")
    var x = range(0, 3)
    var y = range(10, 12)
    var t = move(x)
    x = move(y)
    y = move(t)
    ck(is_order(x, [10, 11]) && is_order(y, [0, 1, 2]), "swap by three moves")
    var e: {u64}
    var f = move(e)
    ck(f.is_empty(), "move of an empty set")
    var s1: {string} = {"a", "b"}
    var s2 = move(s1)
    ck(s2.size() == 2 && s2.contains("b"), "move of strings")
}

fn test_counted() {
    {
        var items: [Ctr]
        for var i: u64 = 0; i < 20; i += 1 { items.push(Ctr(i % 10)) }
        var a = HashSet<Ctr>::from_slice(items)
        ck(a.size() == 10, "counted from_slice drops repeats")
        ck(live == 30, "ten stored copies and twenty sources are alive")
        var b = a.copy()
        ck(b.size() == 10 && live == 40, "copy duplicates each element once")
        var c = move(a)
        ck(c.size() == 10 && live == 40, "a move moves the table, not the elements")
        c = move(b)
        ck(live == 30, "move assignment destroys the old elements")
        var lit = HashSet<Ctr>()
        for var i: u64 = 0; i < 5; i += 1 { lit.insert(Ctr(i)) }
        ck(live == 35, "inserted elements are alive once")
    }
    ck(live == 0, "nothing is left after the scope")
    ck(errors == 0, "no use after a move and no double destroy")
}

fn main() -> i32 {
    test_default()
    test_zero_capacities()
    test_with_capacity()
    test_literal()
    test_from_slice()
    test_from_iter()
    test_copy()
    test_move()
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
