// Strings as keys, in isolation from the sort and the hash table that use
// them. Run by hand (no rows in ops.toml):
//   strkey.order N   `<` of 1024 pairs of N-byte strings of random letters,
//                    which differ within their first bytes
//   strkey.order_prefix N
//                    the same, each pair sharing all but its last byte
//   strkey.eq N      `==` of 1024 pairs, half equal, half differing in the
//                    last byte
// rust/strkey.rs is the twin.
import self::support::*
ffi "c++" import "bench.h"

fn letter(v: u64) -> char {
    var c: char = 97 + (v as u32)
    return c
}

fn letters(rng: *Rng, len: u64, alphabet: u64) -> string {
    var s = string()
    for var i: u64 = 0; i < len; i += 1 { s.push(letter(rng->below(alphabet))) }
    return s
}

fn order(len: u64, shared: bool) {
    const pairs: u64 = 1024
    const passes: u64 = 64
    var rng = Rng()
    var a: [string]
    var b: [string]
    for var i: u64 = 0; i < pairs; i += 1 {
        var s = letters(&rng, len, 26)
        var t = letters(&rng, len, 26)
        if shared {
            t = s.to_owned()
            t.pop()
            t.push(letter(rng.below(26)))
        }
        a.push(s)
        b.push(t)
    }
    var pa: unsafe *const string = &null
    var pb: unsafe *const string = &null
    unsafe {
        pa = &a[0] as unsafe *const string
        pb = &b[0] as unsafe *const string
    }
    bench_begin(pairs * passes)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var p: u64 = 0; p < passes; p += 1 {
            unsafe {
                bench_sink_ptr(pa as unsafe *const void)
                bench_sink_ptr(pb as unsafe *const void)
                for var i: usize = 0; i < pairs as usize; i += 1 {
                    if pa[i] < pb[i] { acc += 1 }
                }
            }
        }
        bench_toc(acc)
    }
    bench_end()
}

fn eq(len: u64) {
    const pairs: u64 = 1024
    const passes: u64 = 64
    var rng = Rng()
    var a: [string]
    var b: [string]
    for var i: u64 = 0; i < pairs; i += 1 {
        var s = letters(&rng, len, 26)
        var t = s.to_owned()
        if (i & 1) != 0 {
            t.pop()
            t.push('Z')
        }
        a.push(s)
        b.push(t)
    }
    var pa: unsafe *const string = &null
    var pb: unsafe *const string = &null
    unsafe {
        pa = &a[0] as unsafe *const string
        pb = &b[0] as unsafe *const string
    }
    bench_begin(pairs * passes)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var p: u64 = 0; p < passes; p += 1 {
            unsafe {
                bench_sink_ptr(pa as unsafe *const void)
                bench_sink_ptr(pb as unsafe *const void)
                for var i: usize = 0; i < pairs as usize; i += 1 {
                    if pa[i] == pb[i] { acc += 1 }
                }
            }
        }
        bench_toc(acc)
    }
    bench_end()
}

fn sized(len: u64) {
    if bench_want("strkey.order", len) { order(len, false) }
    if bench_want("strkey.order_prefix", len) { order(len, true) }
    if bench_want("strkey.eq", len) { eq(len) }
}

fn main() -> i32 {
    bench_init_env()
    sized(3)
    sized(6)
    sized(8)
    sized(12)
    sized(16)
    sized(24)
    sized(32)
    sized(64)
    return 0
}
