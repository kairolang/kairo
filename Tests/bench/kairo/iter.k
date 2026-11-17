// Iterator chain rows (ops.toml, group "iter") on the old library. It has no
// iterator adapters, so the chain rows wait for the new one; the hand-written
// loops (`_loop`) run.
import self::support::*
ffi "c++" import "bench.h"

// Values in [-1000, 1000]: no sum below leaves i32.
fn input(n: u64) -> [i32] {
    var rng = Rng()
    var v: [i32]
    for var i: u64 = 0; i < n; i += 1 { v.push((rng.below(2001) as i32) - 1000) }
    return v
}

fn map_filter_sum(const v: [i32]) -> u64 {
    var sum: i32 = 0
    for var i: usize = 0; i < v.size(); i += 1 {
        var x = v[i] * 3
        if (x & 1) == 0 { sum += x }
    }
    return (sum as i64) as u64
}

fn enumerate_take(const v: [i32]) -> u64 {
    var sum: i64 = 0
    for var i: usize = 0; i < v.size() / 2; i += 1 { sum += (i as i64) * (v[i] as i64) }
    return sum as u64
}

fn rev_take_while_count(const v: [i32]) -> u64 {
    var i = v.size()
    while i != 0 && v[i - 1] != 5000 { i -= 1 }
    return (v.size() - i) as u64
}

fn collect_map(const v: [i32]) -> u64 {
    var out: [i32]
    out.reserve(v.size())
    for var i: usize = 0; i < v.size(); i += 1 { out.push(v[i] * 3) }
    unsafe { bench_sink_ptr(out.data() as unsafe *const void) }
    return out.size() as u64 + ((out[v.size() - 1] as i64) as u64)
}

fn run(which: i32, n: u64) {
    const passes: u64 = (1u64 << 22) / n
    var v = input(n)
    var ops = n * passes
    if which == 1 { ops = (n / 2) * passes }
    bench_begin(ops)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var p: u64 = 0; p < passes; p += 1 {
            unsafe { bench_sink_ptr(v.data() as unsafe *const void) }
            if which == 0 { acc += map_filter_sum(v) }
            else if which == 1 { acc += enumerate_take(v) }
            else if which == 2 { acc += rev_take_while_count(v) }
            else { acc += collect_map(v) }
        }
        bench_toc(acc)
    }
    bench_end()
}

fn rows(n: u64) {
    bench_todo("iter.map_filter_sum", n)
    if bench_want("iter.map_filter_sum_loop", n) { run(0, n) }
    bench_todo("iter.enumerate_take", n)
    if bench_want("iter.enumerate_take_loop", n) { run(1, n) }
    bench_todo("iter.rev_take_while_count", n)
    if bench_want("iter.rev_take_while_count_loop", n) { run(2, n) }
    bench_todo("iter.collect_map", n)
    if bench_want("iter.collect_map_loop", n) { run(3, n) }
}

fn main() -> i32 {
    bench_init_env()
    rows(1000)
    rows(1000000)
    return 0
}
