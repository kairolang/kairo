// Keys whose hash is one constant: every key has the same home slot, so
// every probe walks the whole cluster. Up to 10^4 such keys must insert,
// look up, keep insertion order and remove in random order with the index
// consistent after each removal, and finish. The long-probe defence asks
// for a new seed once per block for such a hash, not once per insert.

import std::io
import self::inputs::table_peek::*

var checks: u64 = 0
var failures: u64 = 0

fn ck(cond: bool, const what: string) {
    checks += 1
    if !cond {
        failures += 1
        io::println(f"FAIL {what}")
    }
}

struct CKey {
    pub var v: u64
}

// The hash writes nothing: one value for every key, whatever the seed.
extend CKey impl Hash {
    fn hash(const self, @inout h: Hasher) {
    }

    fn op == (const self, const o: CKey) -> bool {
        return self.v == o.v
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

fn test_colliding(n: u64) {
    var m: {CKey: u64}
    var bad: u64 = 0
    for var i: u64 = 0; i < n; i += 1 {
        var old? = m.insert(CKey { v: i * 3 }, i)
        if old? { bad += 1 }
        if i % 1000 == 0 && tp_check(const &m) != 0 { bad += 1 }
    }
    ck(bad == 0 && m.size() == n as usize, "insert of colliding keys")
    ck(tp_ok(const &m, "colliding, built"), "consistent when built")
    for var i: u64 = 0; i < n; i += 1 {
        var *v? = m.get(CKey { v: i * 3 })
        if !v? || *v != i { bad += 1 }
        if i < 1000 && m.contains(CKey { v: i * 3 + 1 }) { bad += 1 }
    }
    ck(bad == 0, "lookup hits and misses among colliding keys")
    var j: u64 = 0
    for (k, v) in m {
        if k.v != j * 3 { bad += 1 }
        j += 1
    }
    ck(bad == 0, "insertion order of colliding keys")

    // Random removal; every 16th by shift. The index check after each is
    // linear in the slots, so above 2000 entries it runs every 64th.
    var r = Rng(n)
    var left = n
    while left > 0 {
        var at = r.below(left) as usize
        var k = m.entries()[at].key.v
        if left % 16 == 0 {
            var got? = m.shift_remove(CKey { v: k })
            if !got? || got * 3 != k { bad += 1 }
        } else {
            var got? = m.swap_remove(CKey { v: k })
            if !got? || got * 3 != k { bad += 1 }
        }
        if m.contains(CKey { v: k }) { bad += 1 }
        if (left < 2000 || left % 64 == 0) && tp_check(const &m) != 0 { bad += 1 }
        left -= 1
    }
    ck(bad == 0 && m.size() == 0, f"random removal of {n} colliding keys")
}

fn test_reseed() {
    // 4096 reserved: capacity 7168. Once the keys fill more than ten
    // buckets past their one home, the next key walks past them while under
    // half the slots are full and the table takes a new seed; the hash
    // ignores it, so the block asks no more. The block after the growth
    // past 7168 asks once more.
    var m: {CKey: u64}
    m.reserve(4096)
    var seed = tp_seed(const &m)
    var changes: u64 = 0
    var first_at: u64 = 0
    for var i: u64 = 0; i < 8000; i += 1 {
        m.insert(CKey { v: i }, i)
        if tp_seed(const &m) != seed {
            changes += 1
            if changes == 1 { first_at = i }
            seed = tp_seed(const &m)
        }
    }
    ck(changes == 2, f"one reseed per block for a seed-blind hash ({changes})")
    ck(first_at > 128 && first_at <= 160, f"the first reseed comes after 128 colliding keys ({first_at})")
    ck(tp_ok(const &m, "after reseeds"), "consistent after reseeds")
    var bad: u64 = 0
    var j: u64 = 0
    for (k, v) in m {
        if k.v != j || v != j { bad += 1 }
        j += 1
    }
    for var i: u64 = 0; i < 8000; i += 7 {
        if m[CKey { v: i }] != i { bad += 1 }
    }
    ck(bad == 0, "contents and order after reseeds")

    // A walk of ten buckets or fewer never asks.
    var d: {CKey: u64}
    var dseed = tp_seed(const &d)
    for var i: u64 = 0; i < 120; i += 1 { d.insert(CKey { v: i }, i) }
    ck(tp_seed(const &d) == dseed, "no reseed for a short walk")
}

fn main() -> i32 {
    test_colliding(500)
    test_colliding(10000)
    test_reseed()
    io::println(f"{checks} checks, {failures} failures")
    return failures as i32
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// The tag compare as one 128-bit word, the form targets without SSE2 take.
// RUN: %kairo_new %s -O2 -DKAIRO_TABLE_NO_SIMD -o %t.word.exe --cache-dir %t.dw
// RUN: %t.word.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: {{[0-9]+}} checks, 0 failures
