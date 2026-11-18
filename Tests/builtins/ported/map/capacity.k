// Capacity behaviour of HashMap<K, V>: capacity, reserve (room for n entries
// in all, never shrinks), shrink_to_fit (the smallest block that holds the
// entries; an empty map frees its block), clear (capacity stays), growth
// through many resizes, zero-sized values, and element moves that create and
// destroy nothing.
//
// differs from Rust: `reserve(n)` is room for `n` entries in all, not `n` more
// (hash_map.k, the doc comment on reserve). A map has no load factor, bucket count or rehash: the
// counterparts are capacity() and reserve().
//
// Cases from libc++ test/std/containers/unord/unord.map/ (reserve, rehash, load_factor, size, empty)
// Cases from Rust library/std/src/collections/hash/map/tests.rs
// Cases from hashbrown src/map.rs tests (zero capacities, expand, resize policy, reserve and shrink, lots of insertions)

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

struct Unit {
}

fn test_reserve() {
    var m: {u64: u64}
    m.reserve(0)
    ck(m.capacity() == 0, "reserve(0) on an empty map allocates nothing")
    m.reserve(10)
    ck(m.capacity() >= 10 && m.size() == 0, "reserve(10)")
    var cap = m.capacity()
    for var i: u64 = 0; i < 10; i += 1 { m.insert(i, i) }
    ck(m.capacity() == cap, "no growth while filling to the reserved room")
    m.reserve(5)
    ck(m.capacity() == cap, "reserve below the capacity does nothing (never shrinks)")
    m.reserve(0)
    ck(m.capacity() == cap, "reserve(0) never shrinks")
    m.reserve(1000)
    ck(m.capacity() >= 1000, "reserve(n) is room for n entries in all")
    var big = m.capacity()
    for var i: u64 = 10; i < 1000; i += 1 { m.insert(i, i) }
    ck(m.capacity() == big && m.size() == 1000, "reserved room holds n entries in all without another block")
    var bad: u64 = 0
    var j: u64 = 0
    for (k, v) in m {
        if k != j || v != j { bad += 1 }
        j += 1
    }
    ck(bad == 0, "reserve and growth keep order and contents")
}

fn test_reserve_moves_nothing_visible() {
    var m: {string: u64}
    for var i: u64 = 0; i < 50; i += 1 { m.insert(f"k{i}", i) }
    m.reserve(5000)
    var bad: u64 = 0
    for var i: u64 = 0; i < 50; i += 1 {
        var *p? = m.get(f"k{i}")
        if !p? || *p != i { bad += 1 }
    }
    ck(bad == 0 && m.size() == 50 && m.entries()[0].key == "k0", "reserve keeps string entries and order")
}

fn test_growth() {
    var m: {u64: u64}
    var cap: usize = 0
    var changes: u64 = 0
    var monotone = true
    var enough = true
    for var i: u64 = 0; i < 100000; i += 1 {
        m.insert(i, i)
        if m.capacity() != cap {
            if m.capacity() < cap { monotone = false }
            cap = m.capacity()
            changes += 1
        }
        if m.capacity() < m.size() { enough = false }
    }
    ck(monotone && enough, "growth: capacity never drops and always covers the size")
    ck(changes > 0 && changes <= 40, f"growth is geometric: {changes} blocks for 100000 inserts")
    ck(m.size() == 100000 && m[0] == 0 && m[99999] == 99999 && m[54321] == 54321, "growth: contents after many resizes")
}

fn test_growth_with_strings() {
    var m: {string: string}
    for var i: u64 = 0; i < 20000; i += 1 { m.insert(f"key {i}", f"value {i}") }
    var bad: u64 = 0
    for var i: u64 = 0; i < 20000; i += 1 {
        var *p? = m.get(f"key {i}")
        if !p? || *p != f"value {i}" { bad += 1 }
    }
    ck(bad == 0 && m.size() == 20000, "growth: string entries through many resizes")
    ck(m.entries()[0].key == "key 0" && m.entries()[19999].key == "key 19999", "growth: string order")
}

fn test_shrink_to_fit() {
    var m: {u64: u64}
    m.shrink_to_fit()
    ck(m.capacity() == 0, "shrink_to_fit on an empty never-allocated map")
    for var i: u64 = 0; i < 1000; i += 1 { m.insert(i, i * 2) }
    for var i: u64 = 10; i < 1000; i += 1 { m.pop() }
    var before = m.capacity()
    m.shrink_to_fit()
    ck(m.capacity() < before && m.capacity() >= m.size(), "shrink_to_fit: a smaller block that holds the entries")
    var bad: u64 = 0
    var j: u64 = 0
    for (k, v) in m {
        if k != j || v != j * 2 { bad += 1 }
        j += 1
    }
    ck(bad == 0 && j == 10, "shrink_to_fit keeps order and contents")
    m.insert(500, 1)
    ck(m[500] == 1 && m.size() == 11, "insert after shrink_to_fit")
    var again = m.capacity()
    m.shrink_to_fit()
    ck(m.capacity() <= again && m.size() == 11, "shrink_to_fit twice is stable")
    m.clear()
    ck(m.capacity() > 0, "clear keeps the block")
    m.shrink_to_fit()
    ck(m.capacity() == 0 && m.is_empty(), "shrink_to_fit of an empty map frees its block (hash_map.k)")
    m.insert(1, 1)
    ck(m[1] == 1 && m.capacity() > 0, "insert after the block was freed")
}

fn test_shrink_then_reserve() {
    var m: {u64: u64}
    m.reserve(1000)
    for var i: u64 = 0; i < 20; i += 1 { m.insert(i, i) }
    m.shrink_to_fit()
    ck(m.capacity() < 1000 && m.capacity() >= 20, "reserve then shrink")
    m.reserve(500)
    var room = m.capacity()
    ck(room >= 500, "reserve after shrink")
    for var i: u64 = 20; i < 500; i += 1 { m.insert(i, i) }
    ck(m.capacity() == room, "500 entries in all fit the reserved room")
    ck(m.size() == 500 && m[19] == 19, "contents after reserve, shrink, reserve")
}

fn test_capacity_after_clear() {
    var m: {u64: u64}
    for var i: u64 = 0; i < 300; i += 1 { m.insert(i, i) }
    var cap = m.capacity()
    m.clear()
    ck(m.capacity() == cap, "clear keeps the capacity")
    for var i: u64 = 0; i < 300; i += 1 { m.insert(i + 1000, i) }
    ck(m.capacity() == cap && m.size() == 300, "refill after clear needs no new block")
}

fn test_zero_sized_values() {
    var m: {u64: Unit}
    for var i: u64 = 0; i < 1000; i += 1 { m.insert(i, Unit {}) }
    ck(m.size() == 1000 && m.contains(0) && m.contains(999) && !m.contains(1000), "zero-sized values: insert and contains")
    var r? = m.insert(5, Unit {})
    ck(r? && m.size() == 1000, "zero-sized values: insert reports the replaced value")
    m.swap_remove(5)
    m.shift_remove(6)
    ck(m.size() == 998 && !m.contains(5) && !m.contains(6), "zero-sized values: removal")
    var c = m.copy()
    ck(c.size() == 998 && c.contains(7), "zero-sized values: copy")
    var n: u64 = 0
    for (k, v) in m { n += 1 }
    ck(n == 998, "zero-sized values: iteration")
    var s: {u64: Unit}
    s[3] = Unit {}
    ck(s.size() == 1 && s.contains(3), "zero-sized values: the setter")
}

fn test_counted_capacity() {
    {
        var m: {u64: Obj}
        for var i: u64 = 0; i < 100; i += 1 { m.insert(i, Obj(i)) }
        m.reserve(10000)
        ck(live == 100, "counted: reserve moves entries, creates none")
        for var i: u64 = 10; i < 100; i += 1 { m.pop() }
        m.shrink_to_fit()
        ck(live == 10 && m.size() == 10, "counted: shrink_to_fit moves entries, creates none")
        var bad: u64 = 0
        for var i: u64 = 0; i < 10; i += 1 {
            if m[i].v != i { bad += 1 }
        }
        ck(bad == 0, "counted: values after reserve and shrink")
    }
    ck(live == 0 && errors == 0, "capacity: nothing leaked, nothing destroyed twice")
}

fn main() -> i32 {
    test_reserve()
    test_reserve_moves_nothing_visible()
    test_growth()
    test_growth_with_strings()
    test_shrink_to_fit()
    test_shrink_then_reserve()
    test_capacity_after_clear()
    test_zero_sized_values()
    test_counted_capacity()
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
