// What the Kairo benchmark programs on the two-word library share: the xorshift64 generator every
// language seeds alike (cpp/bench.h, rust/bench.rs).
ffi "c++" import "bench.h"

pub const SEED: u64 = 0x9E3779B97F4A7C15

pub class Rng {
    var s: u64
    pub inline fn Rng(self) { self.s = SEED }
    pub inline fn next(self) -> u64 {
        self.s ^= self.s << 13
        self.s ^= self.s >> 7
        self.s ^= self.s << 17
        return self.s
    }
    // Uniform in [0, n) for n < 2^32, with no division.
    pub inline fn below(self, n: u64) -> u64 { return ((self.next() >> 32) * n) >> 32 }
}
