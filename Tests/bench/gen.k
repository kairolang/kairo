import std::io::println
ffi "c++" import "bench_env.h"

fn upto(n: i64) -> yield i64 {
    for var i: i64 = 0; i < n; i += 1 { yield i }
}

fn squares(n: i64) -> yield i64 {
    for v in upto(n) {
        // Workaround: yield of a temporary fails (yield_value takes @inout).
        var s = v * v % 1000003
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
