// Distribution: 2^20 sequential integers, 2^20 multiples of 4096 and 2^20
// heap-like addresses, bucketed by the top 16 bits of the hash and by bits
// 32..47 (the hash table takes a key's home bucket from the bits at 32 and
// up), four seeds; chi-square one-sided at mean + 5 sd.

import std::io

/// xorshift64*: the same stream on every target.
struct Rng {
    var s: u64
}

extend Rng {
    fn next(self) -> u64 {
        self.s ^= self.s >> 12
        self.s ^= self.s << 25
        self.s ^= self.s >> 27
        return self.s * 0x2545f4914f6cdd1du64
    }

    /// Uniform in [0, n); n > 0.
    fn below(self, n: u64) -> u64 {
        return (self.next() >> 11) % n
    }
}

var failures: i32 = 0

fn fail(const what: string) {
    failures += 1
    if failures <= 20 {
        io::println(f"FAIL: {what}")
    }
}

fn check(ok: bool, const what: string) {
    if !ok {
        fail(what)
    }
}

/// The process exit status: 0 when nothing failed.
fn result(const name: string) -> i32 {
    if failures == 0 {
        io::println(f"ok {name}")
        return 0
    }
    io::println(f"FAILED {name}: {failures} failure(s)")
    return 1
}

// The hasher's byte entry point takes a slice; the tests hold raw pointers.
fn sl(p: unsafe *const u8, n: usize) -> [const u8;] {
    return unsafe Slice<const u8>(p, n)
}

eval BUCKETS: usize = 65536
eval KEYS: u64 = 1048576
// 16 * (65535 + 5 * 362)
eval LIMIT: u64 = 1077520

var counts: [u32; BUCKETS]

fn chi16(seed: u64, step: u64, base: u64, usize_path: bool, shift: u64) -> u64 {
    for var i: usize = 0; i < BUCKETS; i++ {
        counts[i] = 0
    }
    for var i: u64 = 0; i < KEYS; i++ {
        var h = Hasher(seed)
        if usize_path {
            h.write_usize((base + i * step) as usize)
        } else {
            h.write_u64(base + i * step)
        }
        counts[((h.finish() >> shift) & 0xffff) as usize] += 1
    }
    var sum: u64 = 0
    for var i: usize = 0; i < BUCKETS; i++ {
        var d = (counts[i] as i64) - 16
        sum += (d * d) as u64
    }
    return sum
}

fn one(const name: string, seed: u64, step: u64, base: u64, usize_path: bool) {
    var s = chi16(seed, step, base, usize_path, 48)
    io::println(f"  {name} seed={seed}: chi2*16 = {s} (limit {LIMIT})")
    check(s <= LIMIT, f"{name} seed={seed}: {s} > {LIMIT}")
    var t = chi16(seed, step, base, usize_path, 32)
    io::println(f"  {name} seed={seed}, bits 32..47: chi2*16 = {t} (limit {LIMIT})")
    check(t <= LIMIT, f"{name} seed={seed}, bits 32..47: {t} > {LIMIT}")
}

fn main() -> i32 {
    var seeds: [u64; 4] = [0, 1, 0x243f6a8885a308d3u64, 0xffffffffffffffffu64]
    for var k: usize = 0; k < 4; k++ {
        one("sequential", seeds[k], 1, 0, false)
        one("multiples of 4096", seeds[k], 4096, 0, false)
        one("heap-like pointers", seeds[k], 16, 0x10000000u64, true)
    }
    return result("hash_dist")
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok hash_dist
// RUN: %kairo_new %s -O2 -DKAIRO_HASH_NARROW -o %t.narrow.exe --cache-dir %t.dn
// RUN: %t.narrow.exe | %FileCheck %s
