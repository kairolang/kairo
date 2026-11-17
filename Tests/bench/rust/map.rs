// Hash map and set rows (ops.toml, group "map"): HashMap and HashSet. A row
// without a suffix hashes with the default (SipHash-1-3 through RandomState);
// a `_fast` row hashes with bench.rs's fast hasher.
#[path = "bench.rs"]
mod bench;
use bench::{black_box, Bench, FastBuild, Rng, SEED};
use std::collections::hash_map::RandomState;
use std::collections::{HashMap, HashSet};
use std::hash::BuildHasher;

// A bijection on u64, so the "random" keys are distinct.
fn scramble(i: u64) -> u64 {
    i.wrapping_mul(SEED)
}

fn insert<S: BuildHasher + Default>(b: &mut Bench, n: u64, sequential: bool) {
    let mut m: HashMap<u64, u64, S> = HashMap::default();
    b.begin(n);
    while b.next() {
        m = HashMap::default();
        b.tic();
        for i in 0..n {
            m.insert(if sequential { i } else { scramble(i) }, i);
        }
        b.toc(m.len() as u64);
    }
    b.end();
    black_box(&m);
}

fn lookup<S: BuildHasher + Default>(b: &mut Bench, n: u64, hit: bool) {
    let ops = 1u64 << 20;
    let mut m: HashMap<u64, u64, S> = HashMap::with_capacity_and_hasher(n as usize, S::default());
    for i in 0..n {
        m.insert(scramble(i), i);
    }
    b.begin(ops);
    while b.next() {
        let mut rng = Rng::new();
        let mut acc = 0u64;
        b.tic();
        for _ in 0..ops {
            let j = rng.below(n);
            acc += match m.get(&scramble(if hit { j } else { j + n })) {
                Some(v) => *v,
                None => 7,
            };
        }
        b.toc(acc);
    }
    b.end();
}

fn churn<S: BuildHasher + Default>(b: &mut Bench, n: u64) {
    let ops = 1u64 << 20;
    let mut m: HashMap<u64, u64, S> = HashMap::default();
    for i in 0..n {
        m.insert(scramble(i), i);
    }
    let mut next = n;
    b.begin(ops);
    while b.next() {
        b.tic();
        for _ in 0..ops {
            m.remove(&scramble(next - n));
            m.insert(scramble(next), next);
            next += 1;
        }
        b.toc(m.len() as u64);
    }
    b.end();
}

fn iterate(b: &mut Bench, n: u64) {
    let passes = 4u64;
    let mut m: HashMap<u64, u64> = HashMap::new();
    for i in 0..n {
        m.insert(scramble(i), i);
    }
    b.begin(n * passes);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        for _ in 0..passes {
            for (_, v) in black_box(&m) {
                acc += *v;
            }
        }
        b.toc(acc);
    }
    b.end();
}

fn string_keys(n: u64, len: u64) -> Vec<String> {
    let mut rng = Rng::new();
    (0..n).map(|_| rng.letters(len as usize, 26)).collect()
}

fn str_insert(b: &mut Bench, len: u64) {
    let n = 100000u64;
    let keys = string_keys(n, len);
    let mut m: HashMap<String, u64> = HashMap::new();
    b.begin(n);
    while b.next() {
        m = HashMap::new();
        b.tic();
        for i in 0..n {
            m.insert(keys[i as usize].clone(), i);
        }
        b.toc(m.len() as u64);
    }
    b.end();
    black_box(&m);
}

fn str_lookup<S: BuildHasher + Default>(b: &mut Bench, len: u64) {
    let (n, ops) = (100000u64, 1u64 << 18);
    let keys = string_keys(n, len);
    let mut m: HashMap<String, u64, S> = HashMap::default();
    for i in 0..n {
        m.insert(keys[i as usize].clone(), i);
    }
    b.begin(ops);
    while b.next() {
        let mut rng = Rng::new();
        let mut acc = 0u64;
        b.tic();
        for _ in 0..ops {
            acc += match m.get(keys[rng.below(n) as usize].as_str()) {
                Some(v) => *v,
                None => 7,
            };
        }
        b.toc(acc);
    }
    b.end();
}

fn copy(b: &mut Bench, n: u64) {
    let mut m: HashMap<u64, u64> = HashMap::new();
    for i in 0..n {
        m.insert(scramble(i), i);
    }
    let mut c: HashMap<u64, u64> = HashMap::new();
    b.begin(n);
    while b.next() {
        drop(std::mem::take(&mut c));
        b.tic();
        c = m.clone();
        b.toc(c.len() as u64);
    }
    b.end();
    black_box(&c);
}

fn set_insert(b: &mut Bench, n: u64) {
    let mut s: HashSet<u64> = HashSet::new();
    b.begin(n);
    while b.next() {
        s = HashSet::new();
        b.tic();
        for i in 0..n {
            s.insert(scramble(i));
        }
        b.toc(s.len() as u64);
    }
    b.end();
    black_box(&s);
}

fn set_contains(b: &mut Bench, n: u64) {
    let ops = 1u64 << 20;
    let mut s: HashSet<u64> = HashSet::new();
    for i in 0..n {
        s.insert(scramble(i));
    }
    b.begin(ops);
    while b.next() {
        let mut rng = Rng::new();
        let mut acc = 0u64;
        b.tic();
        for _ in 0..ops {
            acc += s.contains(&scramble(rng.below(2 * n))) as u64;
        }
        b.toc(acc);
    }
    b.end();
}

fn main() {
    let b = &mut Bench::init();
    if b.want("map.insert_seq", 1000000) {
        insert::<RandomState>(b, 1000000, true);
    }
    if b.want("map.insert_rand", 1000000) {
        insert::<RandomState>(b, 1000000, false);
    }
    if b.want("map.insert_rand_fast", 1000000) {
        insert::<FastBuild>(b, 1000000, false);
    }
    for n in [1000, 100000, 10000000] {
        if b.want("map.lookup_hit", n) {
            lookup::<RandomState>(b, n, true);
        }
        if b.want("map.lookup_hit_fast", n) {
            lookup::<FastBuild>(b, n, true);
        }
        if b.want("map.lookup_miss", n) {
            lookup::<RandomState>(b, n, false);
        }
        if b.want("map.lookup_miss_fast", n) {
            lookup::<FastBuild>(b, n, false);
        }
    }
    if b.want("map.churn", 100000) {
        churn::<RandomState>(b, 100000);
    }
    if b.want("map.churn_fast", 100000) {
        churn::<FastBuild>(b, 100000);
    }
    if b.want("map.iterate", 1000000) {
        iterate(b, 1000000);
    }
    for n in [8, 32] {
        if b.want("map.str_insert", n) {
            str_insert(b, n);
        }
        if b.want("map.str_lookup", n) {
            str_lookup::<RandomState>(b, n);
        }
        if b.want("map.str_lookup_fast", n) {
            str_lookup::<FastBuild>(b, n);
        }
    }
    if b.want("map.copy", 1000000) {
        copy(b, 1000000);
    }
    if b.want("set.insert_rand", 1000000) {
        set_insert(b, 1000000);
    }
    if b.want("set.contains", 100000) {
        set_contains(b, 100000);
    }
}
