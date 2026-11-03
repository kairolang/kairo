import std::io::println
ffi "c++" import "bench_env.h"
struct Bad { var code: i32 }
fn parse(x: i64) panic(Bad) -> i64 {
    if x % 100 == 0 { panic Bad { code: 1 } }
    return x * 3
}
fn main() -> i32 {
    var n: i64 = bench_n()
    var sum: i64 = 0
    var errs: i64 = 0
    for var i: i64 = 1; i <= n; i += 1 {
        sum += try parse(i) catch e: Bad => fail(e)
    }
    println(f"{sum} {fails}")
    return 0
}
static fails: i64 = 0
fn fail(e: Bad) -> i64 { fails += 1; return 0 }
