// Slice rows (ops.toml, group "slice"): slice methods over Vec storage.
// `sort_unstable` pairs with std::sort, `sort` with std::stable_sort.
#[path = "bench.rs"]
mod bench;
use bench::{black_box, fast_hash_bytes, Bench, Rng};

#[derive(Clone, Copy)]
struct Wide {
    key: u64,
    pad: [u64; 7],
}

trait Element: Clone {
    fn make(rng: &mut Rng, i: u64) -> Self;
    fn digest(&self) -> u64;
    fn sort(v: &mut [Self], stable: bool);
}
impl Element for i32 {
    fn make(rng: &mut Rng, _: u64) -> i32 {
        rng.next() as i32
    }
    fn digest(&self) -> u64 {
        *self as u32 as u64
    }
    fn sort(v: &mut [i32], stable: bool) {
        if stable { v.sort() } else { v.sort_unstable() }
    }
}
impl Element for u64 {
    fn make(rng: &mut Rng, _: u64) -> u64 {
        rng.next()
    }
    fn digest(&self) -> u64 {
        *self
    }
    fn sort(v: &mut [u64], stable: bool) {
        if stable { v.sort() } else { v.sort_unstable() }
    }
}
impl Element for String {
    fn make(rng: &mut Rng, _: u64) -> String {
        rng.letters(16, 26)
    }
    fn digest(&self) -> u64 {
        fast_hash_bytes(self.as_bytes())
    }
    fn sort(v: &mut [String], stable: bool) {
        if stable { v.sort() } else { v.sort_unstable() }
    }
}
impl Element for Wide {
    fn make(rng: &mut Rng, i: u64) -> Wide {
        Wide { key: rng.next(), pad: [i; 7] }
    }
    fn digest(&self) -> u64 {
        self.key ^ self.pad[0]
    }
    fn sort(v: &mut [Wide], stable: bool) {
        if stable {
            v.sort_by(|a, b| a.key.cmp(&b.key))
        } else {
            v.sort_unstable_by(|a, b| a.key.cmp(&b.key))
        }
    }
}

fn sort<T: Element>(b: &mut Bench, n: u64, stable: bool) {
    let mut rng = Rng::new();
    let input: Vec<T> = (0..n).map(|i| T::make(&mut rng, i)).collect();
    let mut work: Vec<T> = Vec::new();
    b.begin(n);
    while b.next() {
        work.clone_from(&input);
        b.tic();
        T::sort(&mut work, stable);
        let n = n as usize;
        b.toc(work[0].digest() ^ work[n / 2].digest().wrapping_mul(3) ^ work[n - 1].digest().wrapping_mul(5));
    }
    b.end();
}

fn binary_search(b: &mut Bench, n: u64) {
    let ops = 1u64 << 16;
    let a: Vec<u64> = (0..n).map(|i| 3 * i + 1).collect();
    b.begin(ops);
    while b.next() {
        let mut rng = Rng::new();
        let mut acc = 0u64;
        b.tic();
        for _ in 0..ops {
            let q = rng.below(3 * n);
            match a.binary_search(&q) {
                Ok(i) => acc += i as u64,
                Err(_) => acc += 1 << 40,
            }
        }
        b.toc(acc);
    }
    b.end();
}

fn reverse(b: &mut Bench, n: u64) {
    let passes = (1u64 << 22) / n | 1;
    let mut a: Vec<u64> = (0..n).collect();
    b.begin(n * passes);
    while b.next() {
        b.tic();
        for _ in 0..passes {
            black_box(&mut a).reverse();
        }
        b.toc(a[0] + a[n as usize - 1]);
    }
    b.end();
}

fn fill(b: &mut Bench, n: u64) {
    let passes = (1u64 << 22) / n;
    let mut a: Vec<u64> = vec![0; n as usize];
    b.begin(n * passes);
    while b.next() {
        b.tic();
        for p in 0..passes {
            a.fill(black_box(p));
            black_box(a.as_ptr());
        }
        b.toc(a[0] + a[n as usize - 1]);
    }
    b.end();
}

fn main() {
    let b = &mut Bench::init();
    let n = 1000000;
    if b.want("slice.sort_unstable_i32", n) {
        sort::<i32>(b, n, false);
    }
    if b.want("slice.sort_unstable_u64", n) {
        sort::<u64>(b, n, false);
    }
    if b.want("slice.sort_unstable_string", n) {
        sort::<String>(b, n, false);
    }
    if b.want("slice.sort_unstable_struct64", n) {
        sort::<Wide>(b, n, false);
    }
    if b.want("slice.sort_stable_i32", n) {
        sort::<i32>(b, n, true);
    }
    if b.want("slice.sort_stable_u64", n) {
        sort::<u64>(b, n, true);
    }
    if b.want("slice.sort_stable_string", n) {
        sort::<String>(b, n, true);
    }
    if b.want("slice.sort_stable_struct64", n) {
        sort::<Wide>(b, n, true);
    }
    for m in [1024, 10000000] {
        if b.want("slice.binary_search", m) {
            binary_search(b, m);
        }
    }
    for m in [4096, 1000000] {
        if b.want("slice.reverse", m) {
            reverse(b, m);
        }
    }
    for m in [4096, 1000000] {
        if b.want("slice.fill", m) {
            fill(b, m);
        }
    }
}
