// Vector rows (ops.toml, group "vector"): Vec.
#[path = "bench.rs"]
mod bench;
use bench::{black_box, Bench, Rng};

fn push_i32(b: &mut Bench, n: u64, reserve: bool) {
    let mut v: Vec<i32> = Vec::new();
    b.begin(n);
    while b.next() {
        v = Vec::new();
        b.tic();
        if reserve {
            v.reserve(n as usize);
        }
        for i in 0..n {
            v.push(i as i32);
        }
        b.toc(v.len() as u64 + v[n as usize - 1] as u64);
    }
    b.end();
    black_box(&v);
}

fn push_string(b: &mut Bench, len: u64) {
    let n = 1000000u64;
    let src = "k".repeat(len as usize);
    let mut v: Vec<String> = Vec::new();
    b.begin(n);
    while b.next() {
        v = Vec::new();
        b.tic();
        for _ in 0..n {
            v.push(String::from(&src[..black_box(len as usize)]));
        }
        b.toc(v.len() as u64 + v[n as usize - 1].len() as u64);
    }
    b.end();
    black_box(&v);
}

fn iter_sum(b: &mut Bench, n: u64) {
    let passes = 10000000 / n;
    let mut rng = Rng::new();
    let v: Vec<i32> = (0..n).map(|_| rng.next() as i32).collect();
    b.begin(n * passes);
    while b.next() {
        let mut sum = 0i64;
        b.tic();
        for _ in 0..passes {
            for &x in black_box(&v) {
                sum += x as i64;
            }
        }
        b.toc(sum as u64);
    }
    b.end();
}

fn insert_front(b: &mut Bench, n: u64) {
    let mut v: Vec<i32> = Vec::new();
    b.begin(n);
    while b.next() {
        v = Vec::new();
        b.tic();
        for i in 0..n {
            v.insert(0, i as i32);
        }
        b.toc(v.len() as u64 + v[0] as u64);
    }
    b.end();
    black_box(&v);
}

fn create_destroy(b: &mut Bench, elements: u64) {
    let ops = 1000000u64;
    b.begin(ops);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        for i in 0..ops {
            let mut v: Vec<i32> = Vec::new();
            if elements != 0 {
                v.push(black_box(i) as i32);
            }
            black_box(&v);
            acc += v.len() as u64;
        }
        b.toc(acc);
    }
    b.end();
}

fn swap_remove(b: &mut Bench, n: u64) {
    let mut v: Vec<i32> = Vec::new();
    b.begin(n);
    while b.next() {
        v.clear();
        v.extend(0..n as i32);
        let mut rng = Rng::new();
        let mut acc = 0u64;
        b.tic();
        while !v.is_empty() {
            let i = rng.below(v.len() as u64) as usize;
            acc = acc.wrapping_mul(31).wrapping_add(v.swap_remove(i) as u64);
        }
        b.toc(acc);
    }
    b.end();
}

fn main() {
    let b = &mut Bench::init();
    if b.want("vector.push_i32", 10000000) {
        push_i32(b, 10000000, false);
    }
    if b.want("vector.push_i32_reserved", 10000000) {
        push_i32(b, 10000000, true);
    }
    // A Kairo-only row: push through a vector variant that keeps its capacity inline.
    if b.want("vector.push_i32_cap24", 10000000) {
        b.skip();
    }
    for n in [8, 32] {
        if b.want("vector.push_string", n) {
            push_string(b, n);
        }
    }
    for n in [10000, 10000000] {
        if b.want("vector.iter_sum", n) {
            iter_sum(b, n);
        }
    }
    if b.want("vector.insert_front", 10000) {
        insert_front(b, 10000);
    }
    for n in [0, 1] {
        if b.want("vector.create_destroy", n) {
            create_destroy(b, n);
        }
    }
    if b.want("vector.swap_remove", 1000000) {
        swap_remove(b, 1000000);
    }
}
