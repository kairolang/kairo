// Slice iteration: sum, dot product and a filtered count over 1M doubles,
// N passes.
import std::io::println
ffi "c++" import "bench_env.h"

static xs: [f64; 1048576]
static ys: [f64; 1048576]

fn main() -> i32 {
    var passes: i64 = bench_n()
    for var i: usize = 0; i < 1048576; i += 1 {
        xs[i] = ((i % 1000) as f64) * 0.5
        ys[i] = ((i % 37) as f64) * 0.25
    }
    var sum = 0.0
    var dot = 0.0
    var big: i64 = 0
    for var p: i64 = 0; p < passes; p += 1 {
        for x in xs { sum += x }
        for var i: usize = 0; i < 1048576; i += 1 { dot += xs[i] * ys[i] }
        for y in ys { if y > 4.0 { big += 1 } }
    }
    println(f"{sum as i64} {dot as i64} {big}")
    return 0
}
