// Spectral norm (benchmarks game), N x N.
import builtin::base::alloc::*
import std::io::println
ffi "c" import "math.h"
ffi "c++" import "bench_env.h"

fn a(i: usize, j: usize) -> f64 { return 1.0 / (((i + j) * (i + j + 1) / 2 + i + 1) as f64) }

fn mul_av(n: usize, v: unsafe *f64, dst: unsafe *f64) {
    for var i: usize = 0; i < n; i += 1 {
        var s = 0.0
        for var j: usize = 0; j < n; j += 1 { unsafe { s += a(i, j) * *(v + j) } }
        unsafe { *(dst + i) = s }
    }
}

fn mul_atv(n: usize, v: unsafe *f64, dst: unsafe *f64) {
    for var i: usize = 0; i < n; i += 1 {
        var s = 0.0
        for var j: usize = 0; j < n; j += 1 { unsafe { s += a(j, i) * *(v + j) } }
        unsafe { *(dst + i) = s }
    }
}

fn mul_atav(n: usize, v: unsafe *f64, dst: unsafe *f64, tmp: unsafe *f64) {
    mul_av(n, v, tmp)
    mul_atv(n, tmp, dst)
}

fn main() -> i32 {
    var n = bench_n() as usize
    var u: unsafe *f64 = &null
    var v: unsafe *f64 = &null
    var t: unsafe *f64 = &null
    unsafe {
        u = alloc_raw(n * sizeof f64, alignof f64) as unsafe *f64
        v = alloc_raw(n * sizeof f64, alignof f64) as unsafe *f64
        t = alloc_raw(n * sizeof f64, alignof f64) as unsafe *f64
        for var i: usize = 0; i < n; i += 1 { *(u + i) = 1.0 }
    }
    for var k = 0; k < 10; k += 1 {
        mul_atav(n, u, v, t)
        mul_atav(n, v, u, t)
    }
    var vbv = 0.0
    var vv = 0.0
    unsafe {
        for var i: usize = 0; i < n; i += 1 {
            vbv += *(u + i) * *(v + i)
            vv += *(v + i) * *(v + i)
        }
    }
    var r = sqrt(vbv / vv)
    unsafe { println(f"{(r * 1000000000.0) as i64}") }
    return 0
}
