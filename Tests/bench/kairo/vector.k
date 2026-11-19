// Vector rows (ops.toml, group "vector"): `[T]` as
// Lib/builtin/containers/vector.k implements it.
import self::support::*
ffi "c++" import "bench.h"
ffi "c++" import "rt/global_alloc.h"

fn push_i32(n: u64, reserve: bool) {
    bench_begin(n)
    while bench_next() {
        var v: [i32]
        bench_tic()
        if reserve {
            v.reserve(n as usize)
        }

        for var i: u64 = 0; i < n; i += 1 {
            v.push(i as i32)
        }

        bench_toc(v.size() as u64 + (v[(n - 1) as usize] as u64))
    }

    bench_end()
}

/// The vector.push_i32_cap24 row: a throwaway three-word vector that keeps
/// its capacity in the object, grown the same way as `[i32]` (double, one
/// cache line at least, realloc), so the row against vector.push_i32 is the
/// cost of reading the capacity from the block.
class Vec24 {
    var buf: unsafe *i32
    var len: usize
    var cap: usize

    pub fn Vec24(self) {
        self.buf = &null
        self.len = 0
        self.cap = 0
    }

    @move pub fn Vec24(self, other: Self) {
        self.buf  = other.buf
        self.len  = other.len
        self.cap  = other.cap
        other.cap = 0
    }

    pub fn op finally(self) {
        if self.cap != 0 {
            unsafe {
                kairo_global_free(self.buf as unsafe *u8, self.cap * 4, 4)
            }
        }
    }

    @hot_path pub inline fn push(self, x: i32) {
        var n = self.len
        @unlikely
        if n == self.cap {
            self.grow()
        }

        unsafe {
            self.buf[n] = x
        }

        self.len = n + 1
    }

    pub inline fn at(const self, i: usize) -> i32 {
        unsafe {
            return self.buf[i]
        }
    }

    @cold_path @no_inline
    fn grow(self) {
        var c = self.cap * 2
        if c < 16 {
            c = 16
        }

        unsafe {
            var unsafe *p = &null as unsafe *u8
            if self.cap == 0 {
                p = kairo_global_alloc(c * 4, 4)
            } else {
                p = kairo_global_realloc(self.buf as unsafe *u8, self.cap * 4, c * 4, 4)
            }

            self.buf = p as unsafe *i32
        }

        self.cap = c
    }
}

fn push_i32_cap24(n: u64) {
    bench_begin(n)
    while bench_next() {
        var v = Vec24()
        bench_tic()
        for var i: u64 = 0; i < n; i += 1 {
            v.push(i as i32)
        }

        bench_toc(v.len as u64 + (v.at((n - 1) as usize) as u64))
    }

    bench_end()
}

fn push_string(len: u64) {
    const n: u64 = 1000000
    // The 32 bytes every size reads a prefix of: 'k' repeated, as in the
    // other columns.
    var src = "kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk"
    bench_begin(n)
    while bench_next() {
        var v: [string]
        bench_tic()
        for var i: u64 = 0; i < n; i += 1 {
            v.push(string(src.data(), bench_opaque(len) as usize))
        }

        bench_toc(v.size() as u64 + (v[(n - 1) as usize].size() as u64))
    }

    bench_end()
}

fn iter_sum(n: u64) {
    const passes: u64 = 10000000 / n
    var rng = Rng()
    var v: [i32]
    for var i: u64 = 0; i < n; i += 1 {
        v.push(rng.next() as i32)
    }

    bench_begin(n * passes)
    while bench_next() {
        var sum: i64 = 0
        bench_tic()
        for var p: u64 = 0; p < passes; p += 1 {
            unsafe {
                bench_sink_ptr(&v[0] as unsafe *const void)
            }

            for x in v {
                sum += x
            }
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
        for var i: u64 = 0; i < n; i += 1 {
            v.insert(0, i as i32)
        }

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
            if elements != 0 {
                v.push(bench_opaque(i) as i32)
            }

            unsafe {
                bench_sink_ptr(&v as unsafe *const void)
            }

            acc += v.size() as u64
        }

        bench_toc(acc)
    }

    bench_end()
}

fn swap_remove(n: u64) {
    var v: [i32]
    bench_begin(n)
    while bench_next() {
        // The refill is untimed but counted: it matches the C++ twin's
        // resize and store, not a push per element.
        v.resize(n as usize, 0)
        for var i: usize = 0; i < v.size(); i += 1 {
            v[i] = i as i32
        }

        var rng      = Rng()
        var acc: u64 = 0
        bench_tic()
        while v.size() != 0 {
            var i = rng.below(v.size() as u64) as usize
            acc = acc * 31 + (v.swap_remove(i) as u64)
        }

        bench_toc(acc)
    }

    bench_end()
}

fn main() -> i32 {
    bench_init_env()
    if bench_want("vector.push_i32", 10000000) {
        push_i32(10000000, false)
    }

    if bench_want("vector.push_i32_reserved", 10000000) {
        push_i32(10000000, true)
    }

    if bench_want("vector.push_i32_cap24", 10000000) {
        push_i32_cap24(10000000)
    }

    if bench_want("vector.push_string", 8) {
        push_string(8)
    }

    if bench_want("vector.push_string", 32) {
        push_string(32)
    }

    if bench_want("vector.iter_sum", 10000) {
        iter_sum(10000)
    }

    if bench_want("vector.iter_sum", 10000000) {
        iter_sum(10000000)
    }

    if bench_want("vector.insert_front", 10000) {
        insert_front(10000)
    }

    if bench_want("vector.create_destroy", 0) {
        create_destroy(0)
    }

    if bench_want("vector.create_destroy", 1) {
        create_destroy(1)
    }

    if bench_want("vector.swap_remove", 1000000) {
        swap_remove(1000000)
    }

    return 0
}
