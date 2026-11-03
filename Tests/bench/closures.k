// Stored callbacks: a pipeline of three capturing closures held as `fn`
// values, applied to N inputs.
import std::io::println
ffi "c++" import "bench_env.h"

fn main() -> i32 {
    var n: i64 = bench_n()
    var k1: i64 = 3
    var k2: i64 = 1000003
    var k3: i64 = 7
    var stages: [fn(i64) -> i64; 3] = [
        fn (x: i64) -> i64 { return x * k1 + 1 },
        fn (x: i64) -> i64 { return x % k2 },
        fn (x: i64) -> i64 { return x ^ k3 },
    ]
    var acc: i64 = 0
    for var i: i64 = 0; i < n; i += 1 {
        var v = i
        for var s: usize = 0; s < 3; s += 1 { v = stages[s](v) }
        acc += v
    }
    println(f"{acc}")
    return 0
}
