// Iterator chain rows (ops.toml, group "iter") on the two-word library:
// std::iter's adapters over a slice's `iter()`, and beside each chain the
// loop a person would write by hand (`_loop`).
import self::support::*
import std::iter::*
ffi "c++" import "bench.h"

// Values in [-1000, 1000]: no sum below leaves i32.
fn input(n: u64) -> [i32] {
    var rng = Rng()
    var v: [i32]
    for var i: u64 = 0; i < n; i += 1 { v.push((rng.below(2001) as i32) - 1000) }
    return v
}

fn triple(x: i32) -> i32 = x * 3
fn is_even(x: *const i32) -> bool = (*x & 1) == 0
fn not_sentinel(p: *const (*const i32)) -> bool = **p != 5000
fn weigh(acc: i64, e: (usize, *const i32)) -> i64 = acc + (e.0 as i64) * (*e.1 as i64)

fn map_filter_sum(const v: [const i32;]) -> u64 {
    var sum: i32 = iter(v.iter()).copied().map(triple).filter(is_even).sum()
    return (sum as i64) as u64
}

fn enumerate_take(const v: [const i32;]) -> u64 {
    return iter(v.iter()).enumerate().take(v.size() / 2).fold<i64>(0, weigh) as u64
}

fn rev_take_while_count(const v: [const i32;]) -> u64 {
    return iter(v.iter()).rev().take_while(not_sentinel).count() as u64
}

fn collect_map(const v: [const i32;]) -> u64 {
    var out = iter(v.iter()).copied().map(triple).collect<[i32]>()
    unsafe { bench_sink_ptr(&out[0] as unsafe *const void) }
    return out.size() as u64 + ((out[v.size() - 1] as i64) as u64)
}

fn map_filter_sum_loop(const v: [const i32;]) -> u64 {
    var sum: i32 = 0
    for var i: usize = 0; i < v.size(); i += 1 {
        var x = v[i] * 3
        if (x & 1) == 0 { sum += x }
    }
    return (sum as i64) as u64
}

fn enumerate_take_loop(const v: [const i32;]) -> u64 {
    var sum: i64 = 0
    for var i: usize = 0; i < v.size() / 2; i += 1 { sum += (i as i64) * (v[i] as i64) }
    return sum as u64
}

fn rev_take_while_count_loop(const v: [const i32;]) -> u64 {
    var i = v.size()
    while i != 0 && v[i - 1] != 5000 { i -= 1 }
    return (v.size() - i) as u64
}

fn collect_map_loop(const v: [const i32;]) -> u64 {
    var out = Vector<i32>::with_capacity(v.size())
    for var i: usize = 0; i < v.size(); i += 1 { out.push(v[i] * 3) }
    unsafe { bench_sink_ptr(&out[0] as unsafe *const void) }
    return out.size() as u64 + ((out[v.size() - 1] as i64) as u64)
}

fn run(which: i32, n: u64) {
    const passes: u64 = (1u64 << 22) / n
    var v = input(n)
    var ops = n * passes
    if which == 2 || which == 3 { ops = (n / 2) * passes }
    bench_begin(ops)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var p: u64 = 0; p < passes; p += 1 {
            unsafe { bench_sink_ptr(&v[0] as unsafe *const void) }
            if which == 0 { acc += map_filter_sum(v) }
            else if which == 1 { acc += map_filter_sum_loop(v) }
            else if which == 2 { acc += enumerate_take(v) }
            else if which == 3 { acc += enumerate_take_loop(v) }
            else if which == 4 { acc += rev_take_while_count(v) }
            else if which == 5 { acc += rev_take_while_count_loop(v) }
            else if which == 6 { acc += collect_map(v) }
            else { acc += collect_map_loop(v) }
        }
        bench_toc(acc)
    }
    bench_end()
}

fn rows(n: u64) {
    if bench_want("iter.map_filter_sum", n) { run(0, n) }
    if bench_want("iter.map_filter_sum_loop", n) { run(1, n) }
    if bench_want("iter.enumerate_take", n) { run(2, n) }
    if bench_want("iter.enumerate_take_loop", n) { run(3, n) }
    if bench_want("iter.rev_take_while_count", n) { run(4, n) }
    if bench_want("iter.rev_take_while_count_loop", n) { run(5, n) }
    if bench_want("iter.collect_map", n) { run(6, n) }
    if bench_want("iter.collect_map_loop", n) { run(7, n) }
}

fn main() -> i32 {
    bench_init_env()
    rows(1000)
    rows(1000000)
    return 0
}
