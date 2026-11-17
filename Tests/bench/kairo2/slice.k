// Slice rows (ops.toml, group "slice") on the two-word library: `[T;]` as
// Lib/builtin2/containers/slice.k implements it. Storage is raw, so the
// rows time the slice methods alone.
import self::support::*
ffi "c++" import "bench.h"
ffi "c++" import "rt/global_alloc.h"

struct Wide {
    var key: u64
    var pad: [u64; 7]
}

extend Wide impl Ord {
    fn op == (const self, const o: Self) -> bool {
        return self.key == o.key
    }

    @no_warn(SC202W)
    fn op <=> (const self, const o: Self) -> Ordering {
        return self.key <=> o.key
    }
}

fn wide_by_key(a: *const Wide, b: *const Wide) -> Ordering {
    return a->key <=> b->key
}

fn <T> alloc_n(n: u64) -> unsafe *T {
    unsafe {
        return kairo_global_alloc((n as usize) * sizeof T, alignof T) as unsafe *T
    }
}

fn <T> free_n(p: unsafe *T, n: u64) {
    unsafe {
        kairo_global_free(p as unsafe *u8, (n as usize) * sizeof T, alignof T)
    }
}

fn <T> copy_n(dst: unsafe *T, src: unsafe *T, n: u64) {
    unsafe {
        __builtin_copy(dst as unsafe *u8, src as unsafe *const u8, (n as usize) * sizeof T)
    }
}

fn digest_i32(x: i32) -> u64 {
    return (x as u32) as u64
}

fn digest_str(const s: string) -> u64 {
    unsafe {
        return bench_fast_hash_bytes(s.data() as unsafe *const u8 as unsafe *const void, s.size())
    }
}

fn digest_wide(const w: Wide) -> u64 {
    return w.key ^ w.pad[0]
}

fn sort_i32(n: u64, stable: bool) {
    var rng          = Rng()
    var unsafe *in_  = alloc_n<i32>(n)
    var unsafe *work = alloc_n<i32>(n)
    unsafe {
        for var i: u64 = 0; i < n; i += 1 {
            in_[i] = rng.next() as i32
        }
    }

    bench_begin(n)
    while bench_next() {
        copy_n<i32>(work, in_, n)
        var s = Slice<i32>(work, n as usize)
        bench_tic()
        if stable {
            s.sort()
        } else {
            s.sort_unstable()
        }

        bench_toc(digest_i32(s[0]) ^ digest_i32(s[(n / 2) as usize]) * 3 ^ digest_i32(s[(n - 1) as usize]) * 5)
    }

    bench_end()
    free_n<i32>(in_, n)
    free_n<i32>(work, n)
}

fn sort_u64(n: u64, stable: bool) {
    var rng          = Rng()
    var unsafe *in_  = alloc_n<u64>(n)
    var unsafe *work = alloc_n<u64>(n)
    unsafe {
        for var i: u64 = 0; i < n; i += 1 {
            in_[i] = rng.next()
        }
    }

    bench_begin(n)
    while bench_next() {
        copy_n<u64>(work, in_, n)
        var s = Slice<u64>(work, n as usize)
        bench_tic()
        if stable {
            s.sort()
        } else {
            s.sort_unstable()
        }

        bench_toc(s[0] ^ s[(n / 2) as usize] * 3 ^ s[(n - 1) as usize] * 5)
    }

    bench_end()
    free_n<u64>(in_, n)
    free_n<u64>(work, n)
}

fn sort_wide(n: u64, stable: bool) {
    var rng          = Rng()
    var unsafe *in_  = alloc_n<Wide>(n)
    var unsafe *work = alloc_n<Wide>(n)
    unsafe {
        for var i: u64 = 0; i < n; i += 1 {
            in_[i].key = rng.next()
            for var j: usize = 0; j < 7; j += 1 {
                in_[i].pad[j] = i
            }
        }
    }

    bench_begin(n)
    while bench_next() {
        copy_n<Wide>(work, in_, n)
        var s = Slice<Wide>(work, n as usize)
        bench_tic()
        if stable {
            s.sort_by(wide_by_key)
        } else {
            s.sort_unstable()
        }

        bench_toc(digest_wide(s[0]) ^ digest_wide(s[(n / 2) as usize]) * 3 ^ digest_wide(s[(n - 1) as usize]) * 5)
    }

    bench_end()
    free_n<Wide>(in_, n)
    free_n<Wide>(work, n)
}

fn sort_string(n: u64, stable: bool) {
    var rng          = Rng()
    var unsafe *in_  = alloc_n<string>(n)
    var unsafe *work = alloc_n<string>(n)
    var buf: [u8; 16]
    unsafe {
        for var i: u64 = 0; i < n; i += 1 {
            for var j: usize = 0; j < 16; j += 1 {
                buf[j] = ('a' as u8) + (rng.below(26) as u8)
            }

            __builtin_construct_at<string>((in_ + i) as unsafe *u8, string(&buf[0] as *const u8, 16))
        }
    }

    bench_begin(n)
    while bench_next() {
        unsafe {
            for var i: u64 = 0; i < n; i += 1 {
                __builtin_construct_at<string>((work + i) as unsafe *u8, in_[i].copy())
            }
        }

        var s = Slice<string>(work, n as usize)
        bench_tic()
        if stable {
            s.sort()
        } else {
            s.sort_unstable()
        }

        bench_toc(digest_str(s[0]) ^ digest_str(s[(n / 2) as usize]) * 3 ^ digest_str(s[(n - 1) as usize]) * 5)
        unsafe {
            for var i: u64 = 0; i < n; i += 1 {
                __builtin_destruct_at(&work[i])
            }
        }
    }

    bench_end()
    unsafe {
        for var i: u64 = 0; i < n; i += 1 {
            __builtin_destruct_at(&in_[i])
        }
    }

    free_n<string>(in_, n)
    free_n<string>(work, n)
}

fn binary_search(n: u64) {
    const ops: u64 = 1 << 16
    var unsafe *a = alloc_n<u64>(n)
    unsafe {
        for var i: u64 = 0; i < n; i += 1 {
            a[i] = 3 * i + 1
        }
    }

    var s = Slice<u64>(a, n as usize)
    bench_begin(ops)
    while bench_next() {
        var rng      = Rng()
        var acc: u64 = 0
        bench_tic()
        for var i: u64 = 0; i < ops; i += 1 {
            var q = rng.below(3 * n)
            var r = s.binary_search(q)
            if r.0 {
                acc += r.1 as u64
            } else {
                acc += 1u64 << 40
            }
        }

        bench_toc(acc)
    }

    bench_end()
    free_n<u64>(a, n)
}

fn reverse(n: u64) {
    const total: u64 = 1 << 22
    var passes        = total / n | 1
    var unsafe *a     = alloc_n<u64>(n)
    unsafe {
        for var i: u64 = 0; i < n; i += 1 {
            a[i] = i
        }
    }

    var s = Slice<u64>(a, n as usize)
    bench_begin(n * passes)
    while bench_next() {
        bench_tic()
        for var p: u64 = 0; p < passes; p += 1 {
            unsafe {
                bench_sink_ptr(a as unsafe *const void)
            }

            s.reverse()
        }

        bench_toc(s[0] + s[(n - 1) as usize])
    }

    bench_end()
    free_n<u64>(a, n)
}

fn fill(n: u64) {
    const total: u64 = 1 << 22
    var passes        = total / n
    var unsafe *a     = alloc_n<u64>(n)
    var s             = Slice<u64>(a, n as usize)
    unsafe {
        for var i: u64 = 0; i < n; i += 1 {
            a[i] = 0
        }
    }

    bench_begin(n * passes)
    while bench_next() {
        bench_tic()
        for var p: u64 = 0; p < passes; p += 1 {
            s.fill(bench_opaque(p))
            unsafe {
                bench_sink_ptr(a as unsafe *const void)
            }
        }

        bench_toc(s[0] + s[(n - 1) as usize])
    }

    bench_end()
    free_n<u64>(a, n)
}

fn main() -> i32 {
    bench_init_env()
    const n: u64 = 1000000
    if bench_want("slice.sort_unstable_i32", n) {
        sort_i32(n, false)
    }

    if bench_want("slice.sort_unstable_u64", n) {
        sort_u64(n, false)
    }

    if bench_want("slice.sort_unstable_string", n) {
        sort_string(n, false)
    }

    if bench_want("slice.sort_unstable_struct64", n) {
        sort_wide(n, false)
    }

    if bench_want("slice.sort_stable_i32", n) {
        sort_i32(n, true)
    }

    if bench_want("slice.sort_stable_u64", n) {
        sort_u64(n, true)
    }

    if bench_want("slice.sort_stable_string", n) {
        sort_string(n, true)
    }

    if bench_want("slice.sort_stable_struct64", n) {
        sort_wide(n, true)
    }

    if bench_want("slice.binary_search", 1024) {
        binary_search(1024)
    }

    if bench_want("slice.binary_search", 10000000) {
        binary_search(10000000)
    }

    if bench_want("slice.reverse", 4096) {
        reverse(4096)
    }

    if bench_want("slice.reverse", 1000000) {
        reverse(1000000)
    }

    if bench_want("slice.fill", 4096) {
        fill(4096)
    }

    if bench_want("slice.fill", 1000000) {
        fill(1000000)
    }

    return 0
}
