// Perf, not correctness: a 3-stage nested generator pipeline runs ~2x the
// instructions per item of the same C++20 coroutine pipeline
// (04_generator_perf.cc): 26.5 vs 13.0 instr/item (callgrind, N=1e6), 1.76 s
// vs 1.33 s at N=1e9 (clang 18, -O3). Frames are not heap-allocated (no
// malloc in main); resumes stay indirect calls where clang's CoroElide
// inlines the whole pipeline. Likely cause: Yield keeps the frame as an
// untyped `unsafe *void` and hands values out through `*T`.
// Build both at -O3 and compare; N=1000000 prints 249791499368 from each:
//   kairo 04_generator_perf.k -I . -O3 -o k && clang++ -O3 -std=c++20 04_generator_perf.cc -o c
//   env N=1000000000 ./k ; env N=1000000000 ./c
ffi "c++" import "bench_env.h"
import std::io::println

fn upto(n: i64) -> yield i64 {
    for var i: i64 = 0; i < n; i += 1 { yield i }
}

fn squares(n: i64) -> yield i64 {
    for v in upto(n) {
        var s = v * v % 1000003   // named: see 03_yield_temporary.k
        yield s
    }
}

fn evens(n: i64) -> yield i64 {
    for v in squares(n) {
        if v % 2 == 0 { yield v }
    }
}

fn main() -> i32 {
    var n: i64 = bench_n()
    var sum: i64 = 0
    for v in evens(n) { sum += v }
    println(f"{sum}")
    return 0
}
