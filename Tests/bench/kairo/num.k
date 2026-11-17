// Number text rows (ops.toml, group "num") on the old library: an f-string
// is its only number-to-text path, and it has no text-to-number one.
import self::support::*
ffi "c++" import "bench.h"

const COUNT: u64 = 4096
const PASSES: u64 = 64

fn u64_to_text(digits: u64) {
    var rng = Rng()
    var v: [u64]
    for var i: u64 = 0; i < COUNT; i += 1 {
        if digits == 4 { v.push(rng.below(10000)) } else { v.push(rng.next()) }
    }
    bench_begin(COUNT * PASSES)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var p: u64 = 0; p < PASSES; p += 1 {
            unsafe { bench_sink_ptr(v.data() as unsafe *const void) }
            var s: string
            for var i: usize = 0; i < COUNT as usize; i += 1 { s += f"{v[i]}" }
            acc += s.size() as u64
        }
        bench_toc(acc)
    }
    bench_end()
}

fn f64_to_text() {
    var rng = Rng()
    var v: [f64]
    for var i: u64 = 0; i < COUNT; i += 1 {
        v.push(((rng.next() >> 11) as f64) * (1.0 / 9007199254740992.0) * 1000000.0)
    }
    bench_begin(COUNT * PASSES)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var p: u64 = 0; p < PASSES; p += 1 {
            unsafe { bench_sink_ptr(v.data() as unsafe *const void) }
            var s: string
            for var i: usize = 0; i < COUNT as usize; i += 1 { s += f"{v[i]}" }
            acc += s.size() as u64
        }
        bench_toc(acc)
    }
    bench_end()
}

fn main() -> i32 {
    bench_init_env()
    if bench_want("num.u64_to_text", 4) { u64_to_text(4) }
    bench_todo("num.text_to_u64", 4)
    if bench_want("num.u64_to_text", 20) { u64_to_text(20) }
    bench_todo("num.text_to_u64", 20)
    if bench_want("num.f64_to_text", 17) { f64_to_text() }
    bench_todo("num.text_to_f64", 17)
    return 0
}
