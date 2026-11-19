// Avalanche: flipping any one input bit flips every output bit with
// probability in [0.45, 0.55], for the integer key and byte keys of every
// read form (1-3 bytes, 4-byte words, overlapping 8-byte words, one and two
// lanes of the long loop).

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

eval SEED: u64 = 0x9d8e6f1c2b3a4857u64
eval MAX_LEN: usize = 100

fn hash_key(p: unsafe *const u8, n: usize, seed: u64) -> u64 {
    var h = Hasher(seed)
    if n == 0 {
        var v: u64 = 0
        unsafe { __builtin_copy(&v as unsafe *u8, p, 8) }
        h.write_u64(v)
    } else {
        h.write(sl(p, n))
    }
    return h.finish()
}

fn run(n: usize, keys: u32) {
    var key: [u8; MAX_LEN]
    var flips: [u32; 64]
    var unsafe *p = unsafe (&key[0] as unsafe *const u8)
    var bytes = if n == 0 => 8usize else => n
    var worst_lo = keys
    var worst_hi = 0u32
    for var bit: usize = 0; bit < bytes * 8; bit++ {
        for var j: usize = 0; j < 64; j++ {
            flips[j] = 0
        }
        var r = Rng { s: 0x1234567u64 + (n as u64) * 977 }
        for var k = 0u32; k < keys; k++ {
            for var i: usize = 0; i < bytes; i++ {
                key[i] = (r.next() >> 56) as u8
            }
            // There are too few 1 and 2 byte keys to average over, so those
            // lengths average over seeds as well.
            var seed = SEED
            if n == 1 || n == 2 {
                seed = r.next()
            }
            var a = hash_key(p, n, seed)
            key[bit >> 3] = key[bit >> 3] ^ ((1u32 << (bit & 7)) as u8)
            var d = a ^ hash_key(p, n, seed)
            for var j: usize = 0; j < 64; j++ {
                flips[j] += ((d >> j) & 1) as u32
            }
        }
        for var j: usize = 0; j < 64; j++ {
            if flips[j] < worst_lo {
                worst_lo = flips[j]
            }
            if flips[j] > worst_hi {
                worst_hi = flips[j]
            }
            // 0.45 <= flips / keys <= 0.55, in integers.
            if flips[j] * 100 < keys * 45 || flips[j] * 100 > keys * 55 {
                fail(f"n={n} input bit {bit} -> output bit {j}: {flips[j]} of {keys}")
            }
        }
    }
    io::println(f"  n={n} keys={keys}: flips in [{worst_lo}, {worst_hi}]")
}

fn main() -> i32 {
    run(0, 10000)
    run(8, 10000)
    run(24, 10000)
    run(1, 4000)
    run(2, 4000)
    run(3, 4000)
    run(5, 4000)
    run(12, 4000)
    run(16, 4000)
    run(17, 4000)
    run(40, 4000)
    run(72, 4000)
    run(100, 4000)
    return result("hash_avalanche")
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok hash_avalanche
// RUN: %kairo %s -O2 -DKAIRO_HASH_NARROW -o %t.narrow.exe --cache-dir %t.dn
// RUN: %t.narrow.exe | %FileCheck %s
