// Number text rows (ops.toml, group "num"):
// `Append::append_to` into one reused string, and `FromStr::from_str` of the
// texts it wrote. The generator is support.k's, inlined so this file builds
// against either library.
ffi "c++" import "bench.h"

const SEED: u64 = 0x9E3779B97F4A7C15
const COUNT: u64 = 4096
const PASSES: u64 = 64

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

fn integers(digits: u64) -> [u64] {
    var rng = Rng()
    var v: [u64]
    for var i: u64 = 0; i < COUNT; i += 1 {
        if digits == 4 { v.push(rng.below(10000)) } else { v.push(rng.next()) }
    }
    return v
}

// In [0, 10^6), with a full 53-bit significand.
fn doubles() -> [f64] {
    var rng = Rng()
    var v: [f64]
    for var i: u64 = 0; i < COUNT; i += 1 {
        v.push(((rng.next() >> 11) as f64) * (1.0 / 9007199254740992.0) * 1000000.0)
    }
    return v
}

fn u64_to_text(digits: u64) {
    var v = integers(digits)
    var s = string()
    bench_begin(COUNT * PASSES)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var p: u64 = 0; p < PASSES; p += 1 {
            unsafe { bench_sink_ptr(&v[0] as unsafe *const void) }
            s.clear()
            for var i: usize = 0; i < COUNT as usize; i += 1 { v[i].append_to(&s) }
            acc += s.size() as u64
        }
        bench_toc(acc)
    }
    bench_end()
}

fn text_to_u64(digits: u64) {
    var v = integers(digits)
    var text: [string]
    for var i: usize = 0; i < COUNT as usize; i += 1 { text.push(v[i] as string) }
    var err = ParseError { at: 0, kind: ParseErrorKind::None }
    bench_begin(COUNT * PASSES)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var p: u64 = 0; p < PASSES; p += 1 {
            unsafe { bench_sink_ptr(&text[0] as unsafe *const void) }
            for var i: usize = 0; i < COUNT as usize; i += 1 { acc += u64::from_str(text[i], &err) ?? 0 }
        }
        bench_toc(acc)
    }
    bench_end()
}

fn f64_to_text() {
    var v = doubles()
    var s = string()
    bench_begin(COUNT * PASSES)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var p: u64 = 0; p < PASSES; p += 1 {
            unsafe { bench_sink_ptr(&v[0] as unsafe *const void) }
            s.clear()
            for var i: usize = 0; i < COUNT as usize; i += 1 { v[i].append_to(&s) }
            acc += s.size() as u64
        }
        bench_toc(acc)
    }
    bench_end()
}

fn text_to_f64() {
    var v = doubles()
    var text: [string]
    for var i: usize = 0; i < COUNT as usize; i += 1 { text.push(v[i] as string) }
    var err = ParseError { at: 0, kind: ParseErrorKind::None }
    bench_begin(COUNT * PASSES)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var p: u64 = 0; p < PASSES; p += 1 {
            unsafe { bench_sink_ptr(&text[0] as unsafe *const void) }
            for var i: usize = 0; i < COUNT as usize; i += 1 {
                acc += (f64::from_str(text[i], &err) ?? 0.0).to_bits()
            }
        }
        bench_toc(acc)
    }
    bench_end()
}

fn main() -> i32 {
    bench_init_env()
    if bench_want("num.u64_to_text", 4) { u64_to_text(4) }
    if bench_want("num.text_to_u64", 4) { text_to_u64(4) }
    if bench_want("num.u64_to_text", 20) { u64_to_text(20) }
    if bench_want("num.text_to_u64", 20) { text_to_u64(20) }
    if bench_want("num.f64_to_text", 17) { f64_to_text() }
    if bench_want("num.text_to_f64", 17) { text_to_f64() }
    return 0
}
