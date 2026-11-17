// Differential fuzz of HashMap<u64, u64> and HashSet<u64> against
// std::unordered_map / std::unordered_set, with a std::vector mirror of the
// insertion order: a seeded xorshift stream of inserts, setters, place
// writes, lookups, swap and shift removals, pops, clears, reserves, shrinks
// and copies over a key space that changes size, so tables grow, shrink and
// collide. Every 512 operations (and after each whole-table operation) the
// full state is compared: size, every entry in order with its value, and
// the table's structure. A failure prints the seed and the operation.
// A third stream runs a map whose key has only 16 hash values, so buckets
// fill and removals leave tombstones.
//
// FUZZ_OPS (operations per seed) and FUZZ_SEEDS set the length; lit runs a
// short stream.

ffi "c" import "stdlib.h"
ffi "c++" import "unordered_map"
ffi "c++" import "unordered_set"
ffi "c++" import "vector"
import std::io
import self::Inputs::table_peek::*

class Rng {
    var s: u64
    pub fn Rng(self, seed: u64) { self.s = seed * 0x9E3779B97F4A7C15 + 0x2545F4914F6CDD1D }
    pub fn next(self) -> u64 {
        self.s ^= self.s << 13
        self.s ^= self.s >> 7
        self.s ^= self.s << 17
        return self.s
    }
    pub fn below(self, n: u64) -> u64 { return self.next() % n }
}

struct Count {
    pub var n: u64
}

extend Count impl Default {
    static fn make_default() -> Count { return Count { n: 0 } }
}

/// The reference: values, insertion order, and each key's place in it.
class Ref {
    pub var val:   cxx::std::unordered_map<u64, u64>
    pub var order: cxx::std::vector<u64>
    pub var pos:   cxx::std::unordered_map<u64, u64>

    pub fn put(self, k: u64, v: u64) {
        if self.val.count(k) == 0 {
            self.pos.insert_or_assign(k, self.order.size() as u64)
            self.order.push_back(k)
        }
        self.val.insert_or_assign(k, v)
    }

    pub fn swap_remove(self, k: u64) {
        var i = self.pos.at(k) as usize
        var last = self.order[self.order.size() - 1]
        self.order[i] = last
        self.pos.insert_or_assign(last, i as u64)
        self.order.pop_back()
        self.pos.erase(k)
        self.val.erase(k)
    }

    pub fn shift_remove(self, k: u64) {
        var i = self.pos.at(k) as usize
        var n = self.order.size()
        for var j = i; j + 1 < n; j += 1 {
            self.order[j] = self.order[j + 1]
            self.pos.insert_or_assign(self.order[j], j as u64)
        }
        self.order.pop_back()
        self.pos.erase(k)
        self.val.erase(k)
    }

    pub fn clear(self) {
        self.val.clear()
        self.order.clear()
        self.pos.clear()
    }
}

var failed: bool = false

fn fail(seed: u64, at: u64, const what: string) {
    if !failed { io::println(f"FAIL seed {seed} at {at}: {what}") }
    failed = true
}

fn same(const m: {u64: u64}, const r: Ref, seed: u64, at: u64) {
    if m.size() != r.order.size() { fail(seed, at, f"size {m.size()} vs {r.order.size()}") }
    var i: usize = 0
    for (k, v) in m {
        if i >= r.order.size() || k != r.order[i] || v != r.val.at(k) {
            fail(seed, at, f"entry {i}")
            return
        }
        i += 1
    }
    var c = tp_check(const &m)
    if c != 0 { fail(seed, at, f"table rule {c}") }
}

fn run_map(seed: u64, ops: u64) {
    var m: {u64: u64}
    var cm: {u64: Count}
    var r = Ref()
    var g = Rng(seed)
    var space: u64 = 64
    for var at: u64 = 0; at < ops && !failed; at += 1 {
        if at % 20000 == 0 {
            var sizes: [u64] = [16, 64, 1000, 5000, 40000]
            space = sizes[g.below(5) as usize]
        }
        var k = g.below(space) * 0x9E3779B97F4A7C15
        var v = g.next()
        var c = g.below(1000)
        if c < 300 {
            var old? = m.insert(k, v)
            var had = r.val.count(k) != 0
            if had != old? || (had && old != r.val.at(k)) { fail(seed, at, "insert result") }
            r.put(k, v)
        } else if c < 400 {
            m[k] = v
            r.put(k, v)
        } else if c < 420 {
            cm[k].n += 1
            if cm[k].n == 0 { fail(seed, at, "place form") }
        } else if c < 600 {
            var *p? = m.get(k)
            var had = r.val.count(k) != 0
            if had != p? { fail(seed, at, "get") }
            if p? && *p != r.val.at(k) { fail(seed, at, "get value") }
            if m.contains(k) != had { fail(seed, at, "contains") }
        } else if c < 780 {
            var got? = m.swap_remove(k)
            var had = r.val.count(k) != 0
            if had != got? || (had && got != r.val.at(k)) { fail(seed, at, "swap_remove result") }
            if had { r.swap_remove(k) }
        } else if c < 800 {
            if r.order.size() < 3000 {
                var got? = m.shift_remove(k)
                var had = r.val.count(k) != 0
                if had != got? || (had && got != r.val.at(k)) { fail(seed, at, "shift_remove result") }
                if had { r.shift_remove(k) }
            }
        } else if c < 900 {
            var p? = m.pop()
            if r.order.size() == 0 {
                if p? { fail(seed, at, "pop on empty") }
            } else {
                var last = r.order[r.order.size() - 1]
                if !p? || p.0 != last || p.1 != r.val.at(last) { fail(seed, at, "pop result") }
                r.swap_remove(last)
            }
        } else if c < 902 {
            m.clear()
            r.clear()
            same(m, r, seed, at)
        } else if c < 905 {
            m.reserve(m.size() + g.below(3000) as usize)
            same(m, r, seed, at)
        } else if c < 908 {
            m.shrink_to_fit()
            same(m, r, seed, at)
        } else if c < 910 {
            var cp = m.copy()
            same(cp, r, seed, at)
        } else {
            var *p? = m.get(k ^ 1)
            if p? != (r.val.count(k ^ 1) != 0) { fail(seed, at, "miss") }
        }
        if at % 512 == 0 { same(m, r, seed, at) }
    }
    same(m, r, seed, ops)
}

fn run_set(seed: u64, ops: u64) {
    var s: {u64}
    var r: cxx::std::unordered_set<u64>
    var g = Rng(seed + 7777)
    for var at: u64 = 0; at < ops && !failed; at += 1 {
        var k = g.below(if (at / 10000) % 2 == 0 => 50u64 else => 3000u64)
        var c = g.below(10)
        if c < 4 {
            var fresh = s.insert(k)
            if fresh != (r.count(k) == 0) { fail(seed, at, "set insert") }
            r.insert(k)
        } else if c < 7 {
            if s.contains(k) != (r.count(k) != 0) { fail(seed, at, "set contains") }
        } else if c < 9 {
            if s.swap_remove(k) != (r.count(k) != 0) { fail(seed, at, "set swap_remove") }
            r.erase(k)
        } else {
            if s.shift_remove(k) != (r.count(k) != 0) { fail(seed, at, "set shift_remove") }
            r.erase(k)
        }
        if at % 512 == 0 {
            if s.size() != r.size() || tp_check(const &s) != 0 { fail(seed, at, "set state") }
            for x in s {
                if r.count(x) == 0 { fail(seed, at, "set element") }
            }
        }
    }
}

/// A key whose hash has 16 values: buckets fill, probe sequences run past
/// them, and removals leave tombstones that later inserts reuse.
struct WKey {
    pub var v: u64
}

extend WKey impl Hash {
    fn hash(const self, @inout h: Hasher) {
        h.write_u64(self.v % 16)
    }

    fn op == (const self, const o: WKey) -> bool {
        return self.v == o.v
    }
}

fn same_weak(const m: {WKey: u64}, const r: Ref, seed: u64, at: u64) {
    if m.size() != r.order.size() { fail(seed, at, f"weak size {m.size()} vs {r.order.size()}") }
    var i: usize = 0
    for (k, v) in m {
        if i >= r.order.size() || k.v != r.order[i] || v != r.val.at(k.v) {
            fail(seed, at, f"weak entry {i}")
            return
        }
        i += 1
    }
    var c = tp_check(const &m)
    if c != 0 { fail(seed, at, f"weak table rule {c}") }
}

fn run_weak(seed: u64, ops: u64) {
    var m: {WKey: u64}
    var r = Ref()
    var g = Rng(seed + 424242)
    var space: u64 = 40
    for var at: u64 = 0; at < ops && !failed; at += 1 {
        if at % 5000 == 0 {
            var sizes: [u64] = [20, 40, 150, 600]
            space = sizes[g.below(4) as usize]
        }
        var k = g.below(space)
        var v = g.next()
        var c = g.below(100)
        if c < 40 {
            var old? = m.insert(WKey { v: k }, v)
            var had = r.val.count(k) != 0
            if had != old? || (had && old != r.val.at(k)) { fail(seed, at, "weak insert result") }
            r.put(k, v)
        } else if c < 60 {
            var *p? = m.get(WKey { v: k })
            var had = r.val.count(k) != 0
            if had != p? { fail(seed, at, "weak get") }
            if p? && *p != r.val.at(k) { fail(seed, at, "weak get value") }
        } else if c < 88 {
            var got? = m.swap_remove(WKey { v: k })
            var had = r.val.count(k) != 0
            if had != got? || (had && got != r.val.at(k)) { fail(seed, at, "weak swap_remove result") }
            if had { r.swap_remove(k) }
        } else if c < 93 {
            var got? = m.shift_remove(WKey { v: k })
            var had = r.val.count(k) != 0
            if had != got? || (had && got != r.val.at(k)) { fail(seed, at, "weak shift_remove result") }
            if had { r.shift_remove(k) }
        } else if c < 98 {
            var p? = m.pop()
            if r.order.size() == 0 {
                if p? { fail(seed, at, "weak pop on empty") }
            } else {
                var last = r.order[r.order.size() - 1]
                if !p? || p.0.v != last || p.1 != r.val.at(last) { fail(seed, at, "weak pop result") }
                r.swap_remove(last)
            }
        } else if c < 99 {
            m.shrink_to_fit()
            same_weak(m, r, seed, at)
        } else {
            m.reserve(m.size() + g.below(200) as usize)
            same_weak(m, r, seed, at)
        }
        if at % 256 == 0 { same_weak(m, r, seed, at) }
    }
    same_weak(m, r, seed, ops)
}

fn env_u64(const name: string, fallback: u64) -> u64 {
    unsafe {
        var unsafe *p = getenv(name.data() as unsafe *const __builtin_c_char)
        if p == &null { return fallback }
        return strtoull(p, &null, 10)
    }
}

fn main() -> i32 {
    var ops = env_u64("FUZZ_OPS", 30000)
    var seeds = env_u64("FUZZ_SEEDS", 2)
    var first = env_u64("FUZZ_SEED0", 1)
    for var seed = first; seed < first + seeds && !failed; seed += 1 {
        run_map(seed, ops)
        run_set(seed, ops)
        run_weak(seed, ops)
    }
    if failed { return 1 }
    io::println(f"ok: {seeds} seeds x {ops} map ops, {ops} set ops and {ops} weak-hash ops")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// The tag compare as one 128-bit word, the form targets without SSE2 take.
// RUN: %kairo_new %s -O2 -DKAIRO_TABLE_NO_SIMD -o %t.word.exe --cache-dir %t.dw
// RUN: %t.word.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: ok: 2 seeds x 30000 map ops
