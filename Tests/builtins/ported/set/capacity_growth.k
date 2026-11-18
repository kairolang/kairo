// Capacity and growth of a HashSet: size, is_empty, capacity, reserve, shrink_to_fit and growth
// through many resizes, including insert/remove churn that leaves deleted slots behind. reserve(n)
// gives room for `n` elements in all and never shrinks; shrink_to_fit frees the block of an empty
// set (the doc comments of `reserve` and `shrink_to_fit`).
//
// Cases from libc++ test/std/containers/unord/unord.set/ (reserve, rehash, size, empty,
// max_size, load_factor)
// Cases from Rust library/std/src/collections/hash/set/tests.rs (test_zero_capacities)
// Cases from Rust hashbrown src/set.rs tests (test_zero_capacities)
//
// Not ported, with the reason: rehash(n) and bucket_count (a Kairo set has no buckets: reserve is
// the counterpart), max_load_factor (not settable), max_size (not part of the API).

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

fn range(lo: u64, hi: u64) -> {u64} {
    var s: {u64}
    for var i = lo; i < hi; i += 1 { s.insert(i) }
    return s
}

fn test_size() {
    var s: {u64}
    ck(s.size() == 0 && s.is_empty(), "empty")
    s.insert(1)
    ck(s.size() == 1 && !s.is_empty(), "one")
    s.insert(1)
    ck(s.size() == 1, "a repeat does not grow the size")
    s.insert(2)
    ck(s.size() == 2, "two")
    s.swap_remove(1)
    ck(s.size() == 1, "one again")
    s.clear()
    ck(s.size() == 0 && s.is_empty(), "cleared")
    var big = range(0, 100000)
    ck(big.size() == 100000, "a hundred thousand")
}

fn test_reserve() {
    var s: {u64}
    s.reserve(10)
    ck(s.capacity() >= 10 && s.size() == 0, "reserve on an empty set")
    var cap = s.capacity()
    for var i: u64 = 0; i < 10; i += 1 { s.insert(i) }
    ck(s.capacity() == cap, "inserts within the reserve do not reallocate")
    s.reserve(5)
    ck(s.capacity() == cap, "reserve of less never shrinks")
    s.reserve(10)
    ck(s.capacity() == cap, "reserve of the same changes nothing")
    s.reserve(1000)
    ck(s.capacity() >= 1000 && s.size() == 10, "reserve grows, keeps the elements")
    var bad: u64 = 0
    for var i: u64 = 0; i < 10; i += 1 {
        if !s.contains(i) { bad += 1 }
    }
    ck(bad == 0, "elements survive the reserve")
    var order_ok = true
    var j: u64 = 0
    for x in s {
        if x != j { order_ok = false }
        j += 1
    }
    ck(order_ok, "the order survives the reserve")
    var cap2 = s.capacity()
    for var i: u64 = 10; i < 1000; i += 1 { s.insert(i) }
    ck(s.capacity() == cap2 && s.size() == 1000, "a thousand inserts fit the reserve")
    s.reserve(0)
    ck(s.capacity() == cap2, "reserve(0) changes nothing")
    var e: {string}
    e.reserve(50)
    ck(e.capacity() >= 50 && e.is_empty(), "reserve on a set of strings")
}

fn test_shrink() {
    var s = range(0, 1000)
    var full = s.capacity()
    s.retain(fn (x: *const u64) -> bool { return *x < 10 })
    ck(s.capacity() == full && s.size() == 10, "removal keeps the capacity")
    s.shrink_to_fit()
    ck(s.capacity() >= 10 && s.capacity() < full, "shrink_to_fit gives back the room")
    var bad: u64 = 0
    for var i: u64 = 0; i < 10; i += 1 {
        if !s.contains(i) { bad += 1 }
    }
    ck(bad == 0 && s.size() == 10, "elements survive the shrink")
    s.clear()
    s.shrink_to_fit()
    ck(s.capacity() == 0, "an empty set frees its block")
    s.insert(3)
    ck(s.size() == 1 && s.contains(3) && s.capacity() >= 1, "a shrunk empty set takes elements")
    var tight = range(0, 100)
    tight.shrink_to_fit()
    var cap = tight.capacity()
    tight.shrink_to_fit()
    ck(tight.capacity() == cap && tight.size() == 100, "a second shrink changes nothing")
    var e: {u64}
    e.shrink_to_fit()
    ck(e.capacity() == 0, "shrink of a set with no block")
}

fn test_growth_many_resizes() {
    var s: {u64}
    var last_cap: usize = 0
    var grows: u64 = 0
    var bad: u64 = 0
    for var i: u64 = 0; i < 200000; i += 1 {
        s.insert(i * 2654435761)
        if s.capacity() != last_cap {
            if s.capacity() < last_cap { bad += 1 }
            last_cap = s.capacity()
            grows += 1
        }
        if s.capacity() < s.size() { bad += 1 }
    }
    ck(bad == 0, "capacity never drops and always covers the size")
    ck(grows >= 10 && grows < 200, "growth is geometric, not per insert")
    ck(s.size() == 200000, "two hundred thousand elements")
    var miss: u64 = 0
    for var i: u64 = 0; i < 200000; i += 1 {
        if !s.contains(i * 2654435761) { miss += 1 }
    }
    ck(miss == 0, "every element survives every resize")
    var j: u64 = 0
    var ok = true
    for x in s {
        if x != j * 2654435761 { ok = false }
        j += 1
    }
    ck(ok && j == 200000, "insertion order survives every resize")
}

fn test_churn() {
    // A small live set under heavy insert and remove: deleted slots must be reused or
    // reclaimed, so capacity stays bounded and lookups stay correct.
    var model: [u8]
    for var i: usize = 0; i < 4096; i += 1 { model.push(0) }
    var s: {u64}
    var r = Rng(7)
    var live: u64 = 0
    var bad: u64 = 0
    for var i: u64 = 0; i < 300000; i += 1 {
        var k = r.below(4096)
        var which = r.below(4)
        if which < 2 {
            var added = s.insert(k)
            if added != (model[k as usize] == 0) { bad += 1 }
            if added { model[k as usize] = 1; live += 1 }
        } else if which == 2 {
            var gone = s.swap_remove(k)
            if gone != (model[k as usize] == 1) { bad += 1 }
            if gone { model[k as usize] = 0; live -= 1 }
        } else {
            var gone = s.shift_remove(k)
            if gone != (model[k as usize] == 1) { bad += 1 }
            if gone { model[k as usize] = 0; live -= 1 }
        }
        if s.size() as u64 != live { bad += 1 }
    }
    ck(bad == 0, "300000 random operations agree with a model")
    for var k: usize = 0; k < 4096; k += 1 {
        if s.contains(k as u64) != (model[k] == 1) { bad += 1 }
    }
    ck(bad == 0, "membership agrees with the model")
    ck(s.capacity() < 50000, "capacity stays bounded under churn")
    var seen: u64 = 0
    for x in s { seen += 1 }
    ck(seen == live, "iteration visits each live element once")
}

fn test_fill_and_empty_cycles() {
    var s: {u64}
    var bad: u64 = 0
    for var round: u64 = 0; round < 20; round += 1 {
        for var i: u64 = 0; i < 1000; i += 1 { s.insert(i + round) }
        if s.size() != 1000 { bad += 1 }
        while s.size() > 0 { s.pop() }
        if !s.is_empty() || s.contains(round) { bad += 1 }
    }
    ck(bad == 0, "twenty fill and pop cycles")
    for var round: u64 = 0; round < 5; round += 1 {
        for var i: u64 = 0; i < 1000; i += 1 { s.insert(i) }
        s.clear()
        s.shrink_to_fit()
        if s.capacity() != 0 { bad += 1 }
    }
    ck(bad == 0, "fill, clear and shrink cycles")
}

fn main() -> i32 {
    test_size()
    test_reserve()
    test_shrink()
    test_growth_many_resizes()
    test_churn()
    test_fill_and_empty_cycles()
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
