// Hasher rows (ops.toml, group "hash") on the two-word library: `Hash::hash`
// of a u64 and `Hasher::write` of a string's bytes, each through a fresh
// Hasher and its `finish`. Kairo has one hasher, so the `_std` and `_fast`
// rows are the same measurement, and the checksum counts the calls (the hash
// values are the library's own). The generator is support.k's, inlined so
// this file builds against either library.
ffi "c++" import "bench.h"

const SEED: u64 = 0x9E3779B97F4A7C15
const HASH_SEED: u64 = 0x243f6a8885a308d3

class Rng {
    var s: u64
    pub fn Rng(self) { self.s = SEED }
    pub inline fn next(self) -> u64 {
        self.s ^= self.s << 13
        self.s ^= self.s >> 7
        self.s ^= self.s << 17
        return self.s
    }
    // Uniform in [0, n) for n < 2^32, with no division.
    pub inline fn below(self, n: u64) -> u64 { return ((self.next() >> 32) * n) >> 32 }
}

fn u64_row() {
    const ops: u64 = 1u64 << 20
    bench_begin(ops)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var i: u64 = 0; i < ops; i += 1 {
            var h = Hasher(HASH_SEED)
            bench_opaque(i).hash(&h)
            acc += h.finish()
        }
        bench_sink(acc)
        bench_toc(ops)
    }
    bench_end()
}

fn bytes_row(len: u64) {
    const keys: u64 = 256
    const passes: u64 = (1u64 << 22) / (keys * len)
    var rng = Rng()
    var k: [string]
    var buf: [u8; 1024]
    for var i: u64 = 0; i < keys; i += 1 {
        for var j: u64 = 0; j < len; j += 1 { buf[j] = ('a' as u8) + (rng.below(26) as u8) }
        k.push(string(&buf[0], len as usize))
    }
    bench_begin(keys * passes)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var p: u64 = 0; p < passes; p += 1 {
            unsafe { bench_sink_ptr(&k[0] as unsafe *const void) }
            for var i: usize = 0; i < keys as usize; i += 1 {
                var h = Hasher(HASH_SEED)
                h.write(k[i].bytes())
                acc += h.finish()
            }
        }
        bench_sink(acc)
        bench_toc(keys * passes)
    }
    bench_end()
}

fn main() -> i32 {
    bench_init_env()
    if bench_want("hash.u64_std", 8) { u64_row() }
    if bench_want("hash.u64_fast", 8) { u64_row() }
    if bench_want("hash.bytes_std", 8) { bytes_row(8) }
    if bench_want("hash.bytes_fast", 8) { bytes_row(8) }
    if bench_want("hash.bytes_std", 16) { bytes_row(16) }
    if bench_want("hash.bytes_fast", 16) { bytes_row(16) }
    if bench_want("hash.bytes_std", 64) { bytes_row(64) }
    if bench_want("hash.bytes_fast", 64) { bytes_row(64) }
    if bench_want("hash.bytes_std", 1024) { bytes_row(1024) }
    if bench_want("hash.bytes_fast", 1024) { bytes_row(1024) }
    return 0
}
