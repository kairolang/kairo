import std::io::println
ffi "c++" import "bench_env.h"

fn fannkuch(n: i32) -> (i32, i32) {
    var perm: [i32; 16]
    var perm1: [i32; 16]
    var count: [i32; 16]
    for var i = 0; i < n; i += 1 { perm1[i] = i }
    var max_flips = 0
    var checksum = 0
    var perm_count = 0
    var r = n
    while true {
        while r != 1 { count[r - 1] = r; r -= 1 }
        for var i = 0; i < n; i += 1 { perm[i] = perm1[i] }
        var flips = 0
        var k = perm[0]
        while k != 0 {
            var i = 0
            var j = k
            while i < j {
                var t = perm[i]
                perm[i] = perm[j]
                perm[j] = t
                i += 1
                j -= 1
            }
            flips += 1
            k = perm[0]
        }
        if flips > max_flips { max_flips = flips }
        if perm_count % 2 == 0 { checksum += flips } else { checksum -= flips }
        while true {
            if r == n { return (checksum, max_flips) }
            var p0 = perm1[0]
            for var i = 0; i < r; i += 1 { perm1[i] = perm1[i + 1] }
            perm1[r] = p0
            count[r] -= 1
            if count[r] > 0 { break }
            r += 1
        }
        perm_count += 1
    }
}

fn main() -> i32 {
    var n = bench_n() as i32
    var res = fannkuch(n)
    println(f"{res.0}\nPfannkuchen({n}) = {res.1}")
    return 0
}
