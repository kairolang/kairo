// Vector rows (ops.toml, group "vector") on the old library: `[T]` as
// Lib/builtin/containers/vector.k implements it.
import self::support::*
ffi "c++" import "bench.h"

fn push_i32(n: u64, reserve: bool) {
    bench_begin(n)
    while bench_next() {
        var v: [i32]
        bench_tic()
        if reserve { v.reserve(n as usize) }
        for var i: u64 = 0; i < n; i += 1 { v.push(i as i32) }
        bench_toc(v.size() as u64 + (v[(n - 1) as usize] as u64))
    }
    bench_end()
}

fn push_string(len: u64) {
    const n: u64 = 1000000
    var src = string('k' as u8, len as usize)
    bench_begin(n)
    while bench_next() {
        var v: [string]
        bench_tic()
        for var i: u64 = 0; i < n; i += 1 { v.push(string(src.raw(), bench_opaque(len) as usize)) }
        bench_toc(v.size() as u64 + (v[(n - 1) as usize].size() as u64))
    }
    bench_end()
}

fn iter_sum(n: u64) {
    const passes: u64 = 10000000 / n
    var rng = Rng()
    var v: [i32]
    for var i: u64 = 0; i < n; i += 1 { v.push(rng.next() as i32) }
    bench_begin(n * passes)
    while bench_next() {
        var sum: i64 = 0
        bench_tic()
        for var p: u64 = 0; p < passes; p += 1 {
            unsafe { bench_sink_ptr(v.data() as unsafe *const void) }
            for x in v { sum += x }
        }
        bench_toc(sum as u64)
    }
    bench_end()
}

fn insert_front(n: u64) {
    bench_begin(n)
    while bench_next() {
        var v: [i32]
        bench_tic()
        for var i: u64 = 0; i < n; i += 1 { v.insert(v.begin(), i as i32) }
        bench_toc(v.size() as u64 + (v[0] as u64))
    }
    bench_end()
}

fn create_destroy(elements: u64) {
    const ops: u64 = 1000000
    bench_begin(ops)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var i: u64 = 0; i < ops; i += 1 {
            var v: [i32]
            if elements != 0 { v.push(bench_opaque(i) as i32) }
            unsafe { bench_sink_ptr(&v as unsafe *const void) }
            acc += v.size() as u64
        }
        bench_toc(acc)
    }
    bench_end()
}

fn main() -> i32 {
    bench_init_env()
    if bench_want("vector.push_i32", 10000000) { push_i32(10000000, false) }
    if bench_want("vector.push_i32_reserved", 10000000) { push_i32(10000000, true) }
    bench_todo("vector.push_i32_cap24", 10000000)
    if bench_want("vector.push_string", 8) { push_string(8) }
    if bench_want("vector.push_string", 32) { push_string(32) }
    if bench_want("vector.iter_sum", 10000) { iter_sum(10000) }
    if bench_want("vector.iter_sum", 10000000) { iter_sum(10000000) }
    if bench_want("vector.insert_front", 10000) { insert_front(10000) }
    if bench_want("vector.create_destroy", 0) { create_destroy(0) }
    if bench_want("vector.create_destroy", 1) { create_destroy(1) }
    // The old vector has no swap_remove.
    bench_todo("vector.swap_remove", 1000000)
    return 0
}
