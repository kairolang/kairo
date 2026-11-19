// Every operation of HashMap<K, V> on keys that collide: a key type whose
// hash takes sixteen values, one whose hash is a constant, and an ordinary
// one for contrast, run on thousands of keys through insert, replace,
// try_insert, the setter and the place form, both removals, pop, retain,
// merge, copy, reserve, shrink_to_fit and clear, with lookups checked after
// each phase. A counted key and value class checks that no object leaks or
// is destroyed twice.
//
// Cases from libc++ test/std/containers/unord/unord.map/ (bucket, insert, erase, find with equal hashes)
// Cases from Rust library/std/src/collections/hash/map/tests.rs
// Cases from hashbrown src/map.rs tests (insert conflicts, conflict remove, lots of insertions)

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

// How a key hashes, chosen per run: 0 writes v % 16 (sixteen distinct hashes
// for any number of keys), 1 writes nothing (one hash for every key), 2 writes
// v (an ordinary spread). Equality is always by v.
var mode: u64 = 0

struct HKey {
    pub var v: u64
}

extend HKey impl Hash {
    fn hash(const self, @inout h: Hasher) {
        if mode == 0 {
            h.write_u64(self.v % 16)
        } else if mode == 2 {
            h.write_u64(self.v)
        }
    }

    fn op == (const self, const o: HKey) -> bool {
        return self.v == o.v
    }
}

extend HKey impl Copyable {
    fn copy(const self) -> HKey { return HKey { v: self.v } }
}

/// Hash-colliding class key that counts its own lives.
class OKey {
    pub var v: u64
    pub fn OKey(self, v: u64) {
        self.v = v
        live += 1
    }
    @move pub fn OKey(self, other: Self) {
        self.v = other.v
        live += 1
    }
    pub fn op finally(self) { live -= 1 }
}

extend OKey impl Hash {
    fn hash(const self, @inout h: Hasher) {
        h.write_u64(self.v % 4)
    }

    fn op == (const self, const o: OKey) -> bool {
        return self.v == o.v
    }
}

fn keep_third(k: *const HKey, v: *u64) -> bool {
    return k->v % 3 == 0
}

fn add(a: u64, b: u64) -> u64 { return a + b }

fn key(i: u64) -> HKey { return HKey { v: i * 5 + 1 } }

fn all_present(const m: {HKey: u64}, from: u64, to: u64) -> bool {
    for var i: u64 = from; i < to; i += 1 {
        var *p? = m.get(key(i))
        if !p? || *p != i { return false }
        if m.contains(HKey { v: i * 5 + 2 }) { return false }
    }
    return true
}

fn run_all(n: u64, label: string) {
    var m: {HKey: u64}
    var bad: u64 = 0
    for var i: u64 = 0; i < n; i += 1 {
        if m.insert(key(i), i)? { bad += 1 }
    }
    ck(bad == 0 && m.size() == n as usize, f"{label}: insert {n} keys")
    ck(all_present(m, 0, n), f"{label}: every key found, no false hit")

    var i: u64 = 0
    for (const *k, v) in m {
        if k->v != key(i).v || v != i { bad += 1 }
        i += 1
    }
    ck(bad == 0 && i == n, f"{label}: insertion order")

    // Replace, try_insert, setter, place form.
    for var j: u64 = 0; j < n; j += 7 {
        var old? = m.insert(key(j), j + 1000000)
        if !old? || old != j { bad += 1 }
        m.insert(key(j), j)
    }
    ck(bad == 0 && m.size() == n as usize, f"{label}: replace keeps one entry per key")
    var t? = m.try_insert(key(3), 99)
    ck(t? && t == 99 && m[key(3)] == 3, f"{label}: try_insert on a present key")
    m[key(5)] = 555
    ck(m[key(5)] == 555 && m.size() == n as usize, f"{label}: setter replaces")
    m[key(5)] = 5
    m[HKey { v: 2 }] = 22
    ck(m.size() == (n + 1) as usize && m[HKey { v: 2 }] == 22, f"{label}: setter inserts")
    m[HKey { v: 2 }] += 1
    m[HKey { v: 7 }] += 4
    ck(m[HKey { v: 2 }] == 23 && m[HKey { v: 7 }] == 4 && m.size() == (n + 2) as usize, f"{label}: place form on a hit and a miss")
    m.swap_remove(HKey { v: 7 })
    m.swap_remove(HKey { v: 2 })
    ck(m.size() == n as usize && all_present(m, 0, n), f"{label}: back to the original entries")

    // Copy, then remove half from the original in an interleaved way.
    var c = m.copy()
    for var j: u64 = 0; j < n; j += 2 {
        var r? = m.swap_remove(key(j))
        if !r? || r != j { bad += 1 }
    }
    for var j: u64 = 1; j < n; j += 4 {
        var r? = m.shift_remove(key(j))
        if !r? || r != j { bad += 1 }
    }
    ck(bad == 0, f"{label}: removals return the values")
    for var j: u64 = 0; j < n; j += 1 {
        var expect = (j % 2 == 1) && (j % 4 != 1)
        if m.contains(key(j)) != expect { bad += 1 }
    }
    ck(bad == 0, f"{label}: exactly the unremoved keys remain")
    ck(all_present(c, 0, n) && c.size() == n as usize, f"{label}: the copy kept every key")

    // Refill the freed keys: tombstones and holes are reused.
    for var j: u64 = 0; j < n; j += 1 { m.insert(key(j), j) }
    ck(m.size() == n as usize && all_present(m, 0, n), f"{label}: refill after removals")

    m.retain(keep_third)
    var kept: u64 = 0
    for (const *k, v) in m {
        if k->v % 3 != 0 { bad += 1 }
        kept += 1
    }
    var want: u64 = 0
    for var j: u64 = 0; j < n; j += 1 {
        if key(j).v % 3 == 0 { want += 1 }
    }
    ck(bad == 0 && kept == want && m.size() == want as usize, f"{label}: retain")
    for var j: u64 = 0; j < n; j += 1 {
        if m.contains(key(j)) != (key(j).v % 3 == 0) { bad += 1 }
    }
    ck(bad == 0, f"{label}: lookups agree with retain")

    // Merge two colliding maps.
    var a: {HKey: u64}
    var b: {HKey: u64}
    for var j: u64 = 0; j < n; j += 1 { a.insert(key(j), 1) }
    for var j: u64 = n / 2; j < n + n / 2; j += 1 { b.insert(key(j), 10) }
    a.merge(b, add)
    ck(a.size() == (n + n / 2) as usize, f"{label}: merge size")
    ck(a[key(0)] == 1 && a[key(n / 2)] == 11 && a[key(n + 1)] == 10, f"{label}: merge values")

    // Pop everything off the original copy.
    var cnt: u64 = 0
    while true {
        var p? = c.pop()
        if !p? { break }
        if p.0.v != key(n - 1 - cnt).v || p.1 != n - 1 - cnt { bad += 1 }
        cnt += 1
    }
    ck(bad == 0 && cnt == n && c.is_empty(), f"{label}: pop drains in reverse insertion order")

    // Reserve, shrink, clear.
    a.reserve(a.size() * 4)
    ck(a.size() == (n + n / 2) as usize && a[key(n)] == 10, f"{label}: reserve")
    a.retain(keep_third)
    a.shrink_to_fit()
    ck(a.capacity() >= a.size() && a.contains(HKey { v: 0 }) == false, f"{label}: shrink after retain")
    a.clear()
    ck(a.is_empty() && !a.contains(key(1)), f"{label}: clear")
    a.insert(key(4), 4)
    ck(a[key(4)] == 4, f"{label}: reuse after clear")
}

fn test_bad_hash() {
    mode = 0
    run_all(2000, "16 hashes")
}

fn test_constant_hash() {
    mode = 1
    run_all(1500, "one hash")
}

fn test_good_hash() {
    mode = 2
    run_all(3000, "spread hash")
}

fn test_small_collisions() {
    mode = 1
    var m: {HKey: u64}
    for var i: u64 = 0; i < 3; i += 1 { m.insert(HKey { v: i }, i) }
    ck(m.size() == 3 && m[HKey { v: 2 }] == 2, "one hash: three keys")
    m.swap_remove(HKey { v: 0 })
    ck(!m.contains(HKey { v: 0 }) && m.contains(HKey { v: 1 }) && m.contains(HKey { v: 2 }), "one hash: removal does not hide later keys")
    m.shift_remove(HKey { v: 1 })
    ck(m.contains(HKey { v: 2 }) && m.size() == 1, "one hash: shift_remove of a middle key")
    mode = 0
}

fn test_counted_collisions() {
    {
        var m: {OKey: OKey}
        for var i: u64 = 0; i < 500; i += 1 { m.insert(OKey(i), OKey(i * 2)) }
        ck(live == 1000, "counted: one object per key and value")
        var bad: u64 = 0
        for var i: u64 = 0; i < 500; i += 1 {
            var *p? = m.get(OKey(i))
            if !p? || p->v != i * 2 { bad += 1 }
        }
        ck(bad == 0 && live == 1000, "counted: lookups with a temporary key leave nothing behind")
        for var i: u64 = 0; i < 500; i += 3 {
            if i % 2 == 0 { m.swap_remove(OKey(i)) } else { m.shift_remove(OKey(i)) }
        }
        ck(live == 2 * m.size() as i64, "counted: removal destroys the entry's key and value")
        for var i: u64 = 0; i < 500; i += 1 { m.insert(OKey(i), OKey(i)) }
        ck(m.size() == 500 && live == 1000, "counted: refill, a present key's new key is destroyed")
        m.clear()
        ck(live == 0, "counted: clear")
    }
    ck(live == 0, "collide: nothing leaked, nothing destroyed twice")
}

fn main() -> i32 {
    test_small_collisions()
    test_bad_hash()
    test_constant_hash()
    test_good_hash()
    test_counted_collisions()
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
