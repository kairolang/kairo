// Hash map and set rows (ops.toml, group "map") on the old library: `{K: V}`
// and `{T}` as Lib/builtin/containers implements them. Kairo has one hasher,
// so a `_fast` row is the same measurement as the row it follows.
import self::support::*
ffi "c++" import "bench.h"

// A bijection on u64, so the "random" keys are distinct.
inline fn scramble(i: u64) -> u64 { return i * SEED }

fn insert(n: u64, sequential: bool) {
    bench_begin(n)
    while bench_next() {
        var m: {u64: u64}
        bench_tic()
        if sequential {
            for var i: u64 = 0; i < n; i += 1 { m.insert(i, i) }
        } else {
            for var i: u64 = 0; i < n; i += 1 { m.insert(scramble(i), i) }
        }
        bench_toc(m.size() as u64)
    }
    bench_end()
}

fn lookup(n: u64, hit: bool) {
    const ops: u64 = 1u64 << 20
    var m: {u64: u64}
    m.reserve(n as usize)
    for var i: u64 = 0; i < n; i += 1 { m.insert(scramble(i), i) }
    var shift: u64 = 0
    if !hit { shift = n }
    bench_begin(ops)
    while bench_next() {
        var rng = Rng()
        var acc: u64 = 0
        bench_tic()
        for var i: u64 = 0; i < ops; i += 1 {
            var *e = m.find(scramble(rng.below(n) + shift))
            if e != m.end() { acc += e->value } else { acc += 7 }
        }
        bench_toc(acc)
    }
    bench_end()
}

fn churn(n: u64) {
    const ops: u64 = 1u64 << 20
    var m: {u64: u64}
    for var i: u64 = 0; i < n; i += 1 { m.insert(scramble(i), i) }
    var next = n
    bench_begin(ops)
    while bench_next() {
        bench_tic()
        for var i: u64 = 0; i < ops; i += 1 {
            m.erase(scramble(next - n))
            m.insert(scramble(next), next)
            next += 1
        }
        bench_toc(m.size() as u64)
    }
    bench_end()
}

fn iterate(n: u64) {
    const passes: u64 = 4
    var m: {u64: u64}
    for var i: u64 = 0; i < n; i += 1 { m.insert(scramble(i), i) }
    bench_begin(n * passes)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var p: u64 = 0; p < passes; p += 1 {
            unsafe { bench_sink_ptr(&m as unsafe *const void) }
            for (k, v) in m { acc += v }
        }
        bench_toc(acc)
    }
    bench_end()
}

fn string_keys(n: u64, len: u64) -> [string] {
    var rng = Rng()
    var keys: [string]
    for var i: u64 = 0; i < n; i += 1 {
        var s: string
        for var j: u64 = 0; j < len; j += 1 { s.push_back(('a' as u8) + (rng.below(26) as u8)) }
        keys.push(s)
    }
    return keys
}

fn str_insert(len: u64) {
    const n: u64 = 100000
    var keys = string_keys(n, len)
    bench_begin(n)
    while bench_next() {
        var m: {string: u64}
        bench_tic()
        for var i: u64 = 0; i < n; i += 1 { m.insert(keys[i as usize], i) }
        bench_toc(m.size() as u64)
    }
    bench_end()
}

fn str_lookup(len: u64) {
    const n: u64 = 100000
    const ops: u64 = 1u64 << 18
    var keys = string_keys(n, len)
    var m: {string: u64}
    for var i: u64 = 0; i < n; i += 1 { m.insert(keys[i as usize], i) }
    bench_begin(ops)
    while bench_next() {
        var rng = Rng()
        var acc: u64 = 0
        bench_tic()
        for var i: u64 = 0; i < ops; i += 1 {
            var *e = m.find(keys[rng.below(n) as usize])
            if e != m.end() { acc += e->value } else { acc += 7 }
        }
        bench_toc(acc)
    }
    bench_end()
}

fn copy_row(n: u64) {
    var m: {u64: u64}
    for var i: u64 = 0; i < n; i += 1 { m.insert(scramble(i), i) }
    bench_begin(n)
    while bench_next() {
        bench_tic()
        var c: {u64: u64} = m
        bench_toc(c.size() as u64)
    }
    bench_end()
}

fn set_insert(n: u64) {
    bench_begin(n)
    while bench_next() {
        var s: {u64}
        bench_tic()
        for var i: u64 = 0; i < n; i += 1 { s.insert(scramble(i)) }
        bench_toc(s.size() as u64)
    }
    bench_end()
}

fn set_contains(n: u64) {
    const ops: u64 = 1u64 << 20
    var s: {u64}
    for var i: u64 = 0; i < n; i += 1 { s.insert(scramble(i)) }
    bench_begin(ops)
    while bench_next() {
        var rng = Rng()
        var acc: u64 = 0
        bench_tic()
        for var i: u64 = 0; i < ops; i += 1 {
            if s.contains(scramble(rng.below(2 * n))) { acc += 1 }
        }
        bench_toc(acc)
    }
    bench_end()
}

fn lookups(n: u64) {
    if bench_want("map.lookup_hit", n) { lookup(n, true) }
    if bench_want("map.lookup_hit_fast", n) { lookup(n, true) }
    if bench_want("map.lookup_miss", n) { lookup(n, false) }
    if bench_want("map.lookup_miss_fast", n) { lookup(n, false) }
}

fn string_rows(len: u64) {
    if bench_want("map.str_insert", len) { str_insert(len) }
    if bench_want("map.str_lookup", len) { str_lookup(len) }
    if bench_want("map.str_lookup_fast", len) { str_lookup(len) }
}

fn main() -> i32 {
    bench_init_env()
    if bench_want("map.insert_seq", 1000000) { insert(1000000, true) }
    if bench_want("map.insert_rand", 1000000) { insert(1000000, false) }
    if bench_want("map.insert_rand_fast", 1000000) { insert(1000000, false) }
    lookups(1000)
    lookups(100000)
    lookups(10000000)
    if bench_want("map.churn", 100000) { churn(100000) }
    if bench_want("map.churn_fast", 100000) { churn(100000) }
    if bench_want("map.iterate", 1000000) { iterate(1000000) }
    string_rows(8)
    string_rows(32)
    if bench_want("map.copy", 1000000) { copy_row(1000000) }
    if bench_want("set.insert_rand", 1000000) { set_insert(1000000) }
    if bench_want("set.contains", 100000) { set_contains(100000) }
    return 0
}
