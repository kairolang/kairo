// Number formatting: N doubles and N integers through f-strings; prints the
// total characters produced.
import std::io::println
ffi "c++" import "bench_env.h"

fn main() -> i32 {
    var n: i64 = bench_n()
    var chars: usize = 0
    for var i: i64 = 0; i < n; i += 1 {
        var d = (i as f64) * 0.37 + 0.001
        var s = f"{d}"
        chars += s.length()
        var t = f"{i * 7919}"
        chars += t.length()
    }
    println(f"{chars}")
    return 0
}
