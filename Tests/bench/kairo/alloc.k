// Allocation rows (ops.toml, group "alloc"): the current-allocator family
// of Lib/builtin/alloc_raw.k (alloc_raw, free_raw, resize_raw) and the
// typed create / destroy of Lib/builtin/base/alloc.k.
import builtin::base::alloc::*
ffi "c++" import "bench.h"

fn pair(size: u64) {
    var ops: u64 = 200000
    if size > 65536 {
        ops = 2000
    }

    bench_begin(ops)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var i: u64 = 0; i < ops; i += 1 {
            var        n  = bench_opaque(size) as usize
            var unsafe *p = alloc_raw(n, 8)
            unsafe {
                p[0] = (i & 255) as u8
                bench_sink_ptr(p as unsafe *const void)
                acc += p[0] as u64
            }

            free_raw(p, n, 8)
        }

        bench_toc(acc)
    }

    bench_end()
}

class Obj16 {
    var a: u64
    var b: u64

    fn Obj16(self, a: u64, b: u64) {
        self.a = a
        self.b = b
    }
}

class Obj64 {
    var a:   u64
    var b:   u64
    var pad: [u64; 6]

    fn Obj64(self, a: u64, b: u64) {
        self.a = a
        self.b = b
    }
}

fn object16() {
    const ops: u64 = 200000
    bench_begin(ops)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var i: u64 = 0; i < ops; i += 1 {
            var *p = create<Obj16>(i, 2u64)
            unsafe {
                bench_sink_ptr(p as unsafe *const void)
            }

            acc += p->a + p->b
            destroy<Obj16>(p)
        }

        bench_toc(acc)
    }

    bench_end()
}

fn object64() {
    const ops: u64 = 200000
    bench_begin(ops)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var i: u64 = 0; i < ops; i += 1 {
            var *p = create<Obj64>(i, 2u64)
            unsafe {
                bench_sink_ptr(p as unsafe *const void)
            }

            acc += p->a + p->b
            destroy<Obj64>(p)
        }

        bench_toc(acc)
    }

    bench_end()
}

// The block addresses, as words: read and written through a raw pointer,
// as the twins index a plain array.
static slot: [usize; 1024]

fn batch(size: u64) {
    const live:   usize = 1024
    const rounds: u64   = 200
    bench_begin(live as u64 * rounds)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var r: u64 = 0; r < rounds; r += 1 {
            var n = bench_opaque(size) as usize
            unsafe {
                var unsafe *s = &slot[0] as unsafe *usize
                for var k: usize = 0; k < live; k += 1 {
                    var unsafe *p = alloc_raw(n, 8)
                    p[0] = (k & 255) as u8
                    s[k] = p as usize
                }

                bench_sink_ptr(s as unsafe *const void)
                for var k: usize = 0; k < live; k += 1 {
                    var unsafe *p = s[k] as unsafe *u8
                    acc += p[0] as u64
                    free_raw(p, n, 8)
                }
            }
        }

        bench_toc(acc)
    }

    bench_end()
}

fn grow(size: u64) {
    const chains: u64 = 500
    var steps: u64    = 0
    for var m: u64 = 16; m < size; m *= 2 {
        steps += 1
    }

    bench_begin(chains * steps)
    while bench_next() {
        var acc: u64 = 0
        bench_tic()
        for var c: u64 = 0; c < chains; c += 1 {
            // 16 bytes, as a value the optimizer knows nothing about.
            var        n  = 16 + (bench_opaque(c) >> 60) as usize
            var unsafe *p = alloc_raw(n, 8)
            unsafe {
                p[0] = 1
                while n < size as usize {
                    p    = resize_raw(p, n, n * 2, 8)
                    p[n] = 1
                    bench_sink_ptr(p as unsafe *const void)
                    acc += (p[0] as u64) + (p[n] as u64)
                    n *= 2
                }
            }

            free_raw(p, n, 8)
        }

        bench_toc(acc)
    }

    bench_end()
}

fn main() -> i32 {
    bench_init_env()
    if bench_want("alloc.pair", 16) { pair(16) }
    if bench_want("alloc.pair", 256) { pair(256) }
    if bench_want("alloc.pair", 4096) { pair(4096) }
    if bench_want("alloc.pair", 1048576) { pair(1048576) }
    if bench_want("alloc.object", 16) { object16() }
    if bench_want("alloc.object", 64) { object64() }
    if bench_want("alloc.batch", 16) { batch(16) }
    if bench_want("alloc.batch", 256) { batch(256) }
    if bench_want("alloc.grow", 1048576) { grow(1048576) }
    return 0
}
