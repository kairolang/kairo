// Deterministic Miller-Rabin for u64 with u128 modular multiplication:
// counts primes in [2^40, 2^40 + N).
import std::io::println
ffi "c++" import "bench_env.h"

fn mulmod(a: u64, b: u64, m: u64) -> u64 {
    return ((a as u128) * (b as u128) % (m as u128)) as u64
}

fn powmod(b0: u64, e0: u64, m: u64) -> u64 {
    var r: u64 = 1
    var b = b0 % m
    var e = e0
    while e > 0 {
        if (e & 1) == 1 { r = mulmod(r, b, m) }
        b = mulmod(b, b, m)
        e >>= 1
    }
    return r
}

fn is_prime(n: u64) -> bool {
    if n < 2 { return false }
    var small: [u64; 12] = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37]
    for var i: usize = 0; i < 12; i += 1 {
        if n % small[i] == 0 { return n == small[i] }
    }
    var d = n - 1
    var s = 0
    while (d & 1) == 0 { d >>= 1; s += 1 }
    for var i: usize = 0; i < 12; i += 1 {
        var x = powmod(small[i], d, n)
        if x == 1 || x == n - 1 { continue }
        var composite = true
        for var r = 1; r < s; r += 1 {
            x = mulmod(x, x, n)
            if x == n - 1 { composite = false; break }
        }
        if composite { return false }
    }
    return true
}

fn main() -> i32 {
    var n = bench_n() as u64
    var base: u64 = 1u64 << 40
    var count = 0
    for var k: u64 = 0; k < n; k += 1 { if is_prime(base + k) { count += 1 } }
    println(f"{count}")
    return 0
}
