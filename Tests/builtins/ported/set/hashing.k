// How elements hash in a HashSet: a constant hash by the thousand, a hash that keeps only a few
// bits, a hash that collides unequal elements in pairs, a record whose equal elements share a
// hash but differ in other fields, an element type with no fields, a set of string and a set of
// strings that share long prefixes. Behaviour must not depend on the hash: membership, insertion
// order, removal and growth are the same for every hash.
//
// Cases from libc++ test/std/containers/unord/unord.set/ (eq.different_hash, hash_function,
// key_eq, find_const, erase_key)
// Cases from Rust library/std/src/collections/hash/set/tests.rs (test_replace, test_insert_does_not_overwrite_the_value)
// Cases from Rust hashbrown src/set.rs tests
//
// Not ported, with the reason: hash_function and key_eq accessors (a Kairo set exposes neither),
// a custom hasher type (the hash is the element's `Hash` impl).

import std::io

var checks: u64 = 0
var failures: u64 = 0

fn ck(cond: bool, const what: string) {
    checks += 1
    if !cond {
        failures += 1
        io::println(f"FAIL {what}")
    }
}

class Rng {
    var s: u64
    pub fn Rng(self, seed: u64) { self.s = seed * 0x9E3779B97F4A7C15 + 1 }
    pub fn next(self) -> u64 {
        self.s ^= self.s << 13
        self.s ^= self.s >> 7
        self.s ^= self.s << 17
        return self.s
    }
    pub fn below(self, n: u64) -> u64 { return self.next() % n }
}

// Every element hashes alike.
struct Const {
    pub var v: u64
}

extend Const impl Hash {
    fn hash(const self, @inout h: Hasher) {
    }

    fn op == (const self, const o: Const) -> bool {
        return self.v == o.v
    }
}

extend Const impl Copyable {
    fn copy(const self) -> Const { return Const { v: self.v } }
}

// Only the low three bits count: eight hash values for the whole set.
struct Low {
    pub var v: u64
}

extend Low impl Hash {
    fn hash(const self, @inout h: Hasher) {
        h.write_u64(self.v & 7)
    }

    fn op == (const self, const o: Low) -> bool {
        return self.v == o.v
    }
}

// Unequal elements 2k and 2k+1 hash alike.
struct Pair {
    pub var v: u64
}

extend Pair impl Hash {
    fn hash(const self, @inout h: Hasher) {
        h.write_u64(self.v / 2)
    }

    fn op == (const self, const o: Pair) -> bool {
        return self.v == o.v
    }
}

// Equal when `id` is equal; `tag` takes no part in hash or equality.
struct Rec {
    pub var id: u64
    pub var tag: string
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
    fn copy(const self) -> Rec { return Rec { id: self.id, tag: self.tag.copy() } }
}

struct Unit {
}

extend Unit impl Hash {
    fn hash(const self, @inout h: Hasher) {
    }

    fn op == (const self, const o: Unit) -> bool {
        return true
    }
}

fn test_constant_hash(n: u64) {
    var s: {Const}
    var bad: u64 = 0
    for var i: u64 = 0; i < n; i += 1 {
        if !s.insert(Const { v: i * 3 }) { bad += 1 }
    }
    ck(bad == 0 && s.size() == n as usize, "insert of colliding elements")
    for var i: u64 = 0; i < n; i += 1 {
        if !s.contains(Const { v: i * 3 }) { bad += 1 }
        if i < 500 && s.contains(Const { v: i * 3 + 1 }) { bad += 1 }
        if i < 500 && s.insert(Const { v: i * 3 }) { bad += 1 }
    }
    ck(bad == 0, "lookup of colliding elements")
    var i: u64 = 0
    for const *x in s {
        if x->v != i * 3 { bad += 1 }
        i += 1
    }
    ck(bad == 0 && i == n, "colliding elements keep insertion order")
    var r = Rng(11)
    for var k: u64 = 0; k < n / 2; k += 1 {
        var key = r.below(n) * 3
        s.swap_remove(Const { v: key })
    }
    var present: u64 = 0
    for var k: u64 = 0; k < n; k += 1 {
        if s.contains(Const { v: k * 3 }) { present += 1 }
    }
    ck(present == s.size() as u64, "colliding elements after random removals")
    var c = s.copy()
    ck(c == s && c.size() == s.size(), "copy and equality of colliding elements")
    while s.size() > 0 { s.pop() }
    ck(s.is_empty(), "colliding set popped empty")
}

fn test_low_bits_hash() {
    var s: {Low}
    for var i: u64 = 0; i < 4000; i += 1 { s.insert(Low { v: i }) }
    var bad: u64 = 0
    for var i: u64 = 0; i < 4000; i += 1 {
        if !s.contains(Low { v: i }) { bad += 1 }
        if s.contains(Low { v: i + 4000 }) { bad += 1 }
    }
    ck(bad == 0 && s.size() == 4000, "eight hash values for 4000 elements")
    for var i: u64 = 0; i < 4000; i += 2 { s.shift_remove(Low { v: i }) }
    for var i: u64 = 0; i < 4000; i += 1 {
        if s.contains(Low { v: i }) != (i % 2 == 1) { bad += 1 }
    }
    ck(bad == 0 && s.size() == 2000, "removals among colliding elements")
}

fn test_pair_collisions() {
    var s: {Pair}
    for var i: u64 = 0; i < 6000; i += 1 { s.insert(Pair { v: i }) }
    var bad: u64 = 0
    for var i: u64 = 0; i < 6000; i += 1 {
        if !s.contains(Pair { v: i }) { bad += 1 }
    }
    ck(bad == 0 && s.size() == 6000, "unequal elements with equal hashes are distinct")
    ck(!s.contains(Pair { v: 6000 }), "a miss in a colliding pair")
    s.swap_remove(Pair { v: 10 })
    ck(!s.contains(Pair { v: 10 }) && s.contains(Pair { v: 11 }), "removing one of a colliding pair leaves the other")
}

fn test_record_replace_rule() {
    var s: {Rec}
    ck(s.insert(Rec { id: 1, tag: "first" }), "record inserted")
    ck(!s.insert(Rec { id: 1, tag: "second" }), "an equal record with another tag is not new")
    var *p? = s.get(Rec { id: 1, tag: "probe" })
    ck(p? && p->tag == "first", "insert kept the stored record")
    var old? = s.replace(Rec { id: 1, tag: "third" })
    ck(old? && s.size() == 1, "replace returns the previous record")
    if old? { ck(old.tag == "first", "the previous record carries its own tag") }
    var *q? = s.get(Rec { id: 1, tag: "probe" })
    ck(q? && q->tag == "third", "replace stored the new record")
    var t? = s.take(Rec { id: 1, tag: "probe" })
    ck(t? && s.is_empty(), "take removes the equal record")
    if t? { ck(t.tag == "third", "take returns the stored record, not the probe") }
    s.insert(Rec { id: 2, tag: "x" })
    ck(s.swap_remove(Rec { id: 2, tag: "other" }) && s.is_empty(), "removal by an equal record with another tag")
    var a: {Rec} = {Rec { id: 5, tag: "p" }}
    var b: {Rec} = {Rec { id: 5, tag: "q" }}
    ck(a == b, "sets of records compare by the record's equality")
    var c = a.copy()
    var *cp? = c.get(Rec { id: 5, tag: "" })
    ck(cp? && cp->tag == "p", "a copy carries the stored tags")
}

fn test_unit_elements() {
    var s: {Unit}
    ck(s.insert(Unit {}), "the first element of an empty-struct set is new")
    ck(!s.insert(Unit {}), "the second is a repeat")
    ck(s.size() == 1 && s.contains(Unit {}), "one element")
    var old? = s.replace(Unit {})
    ck(old? && s.size() == 1, "replace of the one value")
    var t? = s.take(Unit {})
    ck(t? && s.is_empty(), "take of the one value")
    ck(!s.contains(Unit {}) && !s.swap_remove(Unit {}), "gone")
    s.insert(Unit {})
    var c = s.copy()
    ck(c == s && c.size() == 1, "copy of the one value")
    s.clear()
    ck(s.is_empty() && !(c == s), "clear")
    var p? = c.pop()
    ck(p? && c.is_empty(), "pop of the one value")
}

fn test_strings() {
    var s: {string}
    for var i: u32 = 0; i < 3000; i += 1 { s.insert(f"a-shared-prefix-for-every-key-{i}") }
    var bad: u32 = 0
    for var i: u32 = 0; i < 3000; i += 1 {
        if !s.contains(f"a-shared-prefix-for-every-key-{i}") { bad += 1 }
        if s.contains(f"a-shared-prefix-for-every-key-{i}x") { bad += 1 }
    }
    ck(bad == 0 && s.size() == 3000, "strings that share a long prefix")
    var t: {string}
    t.insert("ab")
    t.insert("a")
    t.insert("")
    t.insert("b")
    ck(t.size() == 4 && t.contains("a") && t.contains("b") && t.contains("ab") && t.contains(""), "short strings and the empty string")
    var cut: {string}
    cut.insert("abc")
    ck(!cut.contains("ab") && !cut.contains("abcd") && !cut.contains("bc"), "substrings and extensions are not members")
    var u: {string} = {"héllo", "日本語", "🙂"}
    ck(u.contains("héllo") && u.contains("日本語") && u.contains("🙂") && !u.contains("hello"), "UTF-8 strings")
    var c = s.copy()
    ck(c == s && c.size() == 3000, "copy of a set of 3000 strings")
    c.swap_remove("a-shared-prefix-for-every-key-1")
    ck(c != s && s.contains("a-shared-prefix-for-every-key-1"), "the copy owns its strings")
}

fn main() -> i32 {
    test_constant_hash(5000)
    test_low_bits_hash()
    test_pair_collisions()
    test_record_replace_rule()
    test_unit_elements()
    test_strings()
    io::println(f"{checks} checks, {failures} failures")
    return failures as i32
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: {{[0-9]+}} checks, 0 failures
