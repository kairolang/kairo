// See wideint.k. u128 for the modular multiply.
fn mulmod(a: u64, b: u64, m: u64) -> u64 { (a as u128 * b as u128 % m as u128) as u64 }
fn powmod(mut b: u64, mut e: u64, m: u64) -> u64 {
    let mut r = 1; b %= m;
    while e > 0 { if e & 1 == 1 { r = mulmod(r, b, m); } b = mulmod(b, b, m); e >>= 1; }
    r
}
fn is_prime(n: u64) -> bool {
    if n < 2 { return false; }
    const SMALL: [u64; 12] = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37];
    for &p in &SMALL { if n % p == 0 { return n == p; } }
    let (mut d, mut s) = (n - 1, 0);
    while d & 1 == 0 { d >>= 1; s += 1; }
    'outer: for &a in &SMALL {
        let mut x = powmod(a, d, n);
        if x == 1 || x == n - 1 { continue; }
        for _ in 1..s { x = mulmod(x, x, n); if x == n - 1 { continue 'outer; } }
        return false;
    }
    true
}
fn main() {
    let n: u64 = std::env::var("N").unwrap().parse().unwrap();
    let base = 1u64 << 40;
    println!("{}", (0..n).filter(|k| is_prime(base + k)).count());
}
