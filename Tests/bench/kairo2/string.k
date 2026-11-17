// String rows (ops.toml, group "string") on the two-word library: `string`
// as Lib/builtin2/string.k implements it.
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

fn create_destroy(len: u64) {
    const ops: u64 = 200000
    var rng = Rng()
    var src = letters(&rng, len, 26)
    bench_begin(ops)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var i: u64 = 0; i < ops; i += 1 {
            var s = string(src.data(), bench_opaque(len) as usize)
            unsafe { bench_sink_ptr(s.data() as unsafe *const void) }
            acc += s.size() as u64
        }
        bench_toc(acc)
    }
    bench_end()
}

fn push_byte(n: u64) {
    bench_begin(n)
    while bench_next() {
        var s = string()
        bench_tic()
        for var i: u64 = 0; i < n; i += 1 { s.push(letter(i & 15)) }
        bench_toc(s.size() as u64 + (s[(n - 1) as usize] as u64))
    }
    bench_end()
}

fn append_literal(len: u64) {
    const ops: u64 = 100000
    bench_begin(ops)
    while bench_next() {
        var s = string()
        bench_tic()
        if len == 4 {
            for var i: u64 = 0; i < ops; i += 1 { s += "abcd" }
        } else {
            for var i: u64 = 0; i < ops; i += 1 { s += "hello, world" }
        }
        bench_toc(s.size() as u64)
    }
    bench_end()
}

fn find(n: u64) {
    const ops: u64 = (1u64 << 22) / n
    var rng = Rng()
    var hay = letters(&rng, n, 16)
    hay.pop()
    hay.push('z')
    var needle = hay[((n - 8) as usize)..].to_owned()
    bench_begin(ops)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var i: u64 = 0; i < ops; i += 1 {
            unsafe {
                bench_sink_ptr(hay.data() as unsafe *const void)
                bench_sink_ptr(needle.data() as unsafe *const void)
            }
            acc += (hay.find(needle) ?? 0) as u64
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
    // The keys are read through the vectors' element pointers, as the C++
    // twin's `a[i] == b[i]` compiles to: the row times `==`, not the index.
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

// UTF-8 text of exactly n bytes: seven in ten code points are one byte, two
// are two bytes (U+00C0..U+00FF), one is three (U+2080..U+20BF).
fn utf8_text(n: u64) -> string {
    var rng = Rng()
    var s = string()
    while s.size() as u64 + 3 <= n {
        var kind = rng.below(10)
        var c: char = 0
        if kind < 7 {
            c = 97 + (rng.below(26) as u32)
        } else if kind < 9 {
            c = 0xC0 + (rng.below(64) as u32)
        } else {
            c = 0x2080 + (rng.below(64) as u32)
        }
        s.push(c)
    }
    while (s.size() as u64) < n { s.push('x') }
    return s
}

// A heap string stores its count, so the cold row counts a view of the text:
// a view of non-ASCII text is counted each time it is asked. One operation
// is one byte scanned.
fn codepoints(n: u64) {
    const passes: u64 = (1u64 << 22) / n
    var s = utf8_text(n)
    bench_begin(n * passes)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var p: u64 = 0; p < passes; p += 1 {
            var v = s.view()
            unsafe { bench_sink_ptr(&v as unsafe *const void) }
            acc += v.codepoints() as u64
        }
        bench_toc(acc)
    }
    bench_end()
}

// The cached row reads the stored count: one operation is one call.
fn codepoints_cached(n: u64) {
    const calls: u64 = 1u64 << 20
    var s = utf8_text(n)
    bench_begin(calls)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var i: u64 = 0; i < calls; i += 1 {
            unsafe { bench_sink_ptr(&s as unsafe *const void) }
            acc += s.codepoints() as u64
        }
        bench_toc(acc)
    }
    bench_end()
}

fn main() -> i32 {
    bench_init_env()
    if bench_want("string.create_destroy", 0) { create_destroy(0) }
    if bench_want("string.create_destroy", 8) { create_destroy(8) }
    if bench_want("string.create_destroy", 32) { create_destroy(32) }
    if bench_want("string.create_destroy", 256) { create_destroy(256) }
    if bench_want("string.push_byte", 1048576) { push_byte(1048576) }
    if bench_want("string.append_literal", 4) { append_literal(4) }
    if bench_want("string.append_literal", 12) { append_literal(12) }
    if bench_want("string.find", 64) { find(64) }
    if bench_want("string.find", 4096) { find(4096) }
    if bench_want("string.find", 1048576) { find(1048576) }
    if bench_want("string.eq", 8) { eq(8) }
    if bench_want("string.eq", 16) { eq(16) }
    if bench_want("string.codepoints", 4096) { codepoints(4096) }
    if bench_want("string.codepoints", 1048576) { codepoints(1048576) }
    if bench_want("string.codepoints_cached", 4096) { codepoints_cached(4096) }
    if bench_want("string.codepoints_cached", 1048576) { codepoints_cached(1048576) }
    return 0
}
