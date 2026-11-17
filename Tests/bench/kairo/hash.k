// Hasher rows (ops.toml, group "hash") on the old library: `Hash::hash` as
// Lib/builtin/base/hash.k implements it. Kairo has one hasher, so the `_std`
// and `_fast` rows are the same measurement, and the checksum counts the
// calls (the hash values are the library's own).
import self::support::*
ffi "c++" import "bench.h"

fn u64_row() {
    const ops: u64 = 1u64 << 20
    bench_begin(ops)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var i: u64 = 0; i < ops; i += 1 { acc += bench_opaque(i).hash() as u64 }
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
    for var i: u64 = 0; i < keys; i += 1 {
        var s: string
        for var j: u64 = 0; j < len; j += 1 { s.push_back(('a' as u8) + (rng.below(26) as u8)) }
        k.push(s)
    }
    bench_begin(keys * passes)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var p: u64 = 0; p < passes; p += 1 {
            unsafe { bench_sink_ptr(k.data() as unsafe *const void) }
            for var i: usize = 0; i < keys as usize; i += 1 { acc += k[i].hash() as u64 }
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
