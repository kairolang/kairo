// The measuring protocol of the builtin-library benchmarks in Rust: the same
// rules, output and inputs as cpp/bench.h, which documents them. Each program
// in this directory pulls this file in with `#[path = "bench.rs"] mod bench;`.
#![allow(dead_code)]

use std::hash::{BuildHasherDefault, Hasher};
pub use std::hint::black_box;
use std::time::Instant;

pub struct Bench {
    want_id: String,
    want_size: Option<u64>,
    min_total_ns: u64,
    fixed_reps: u64,
    id: String,
    size: u64,
    ops: u64,
    reps: u64,
    min_ns: u64,
    total_ns: u64,
    t0: Instant,
    check: u64,
    warm: bool,
}

impl Bench {
    // `prog <id|all|list> [size] [--min-ms=N] [--reps=K]`, or the same four
    // from BENCH_ROW, BENCH_SIZE, BENCH_MIN_MS and BENCH_REPS.
    pub fn init() -> Bench {
        let env = |k: &str| std::env::var(k).ok();
        let (mut id, mut size) = (env("BENCH_ROW"), env("BENCH_SIZE"));
        let (mut min_ms, mut reps) = (env("BENCH_MIN_MS"), env("BENCH_REPS"));
        let mut pos = 0;
        for a in std::env::args().skip(1) {
            if let Some(v) = a.strip_prefix("--min-ms=") {
                min_ms = Some(v.to_string());
            } else if let Some(v) = a.strip_prefix("--reps=") {
                reps = Some(v.to_string());
            } else if pos == 0 {
                id = Some(a);
                pos += 1;
            } else {
                size = Some(a);
            }
        }
        let num = |v: Option<String>, d: u64| v.and_then(|s| s.parse().ok()).unwrap_or(d);
        Bench {
            want_id: id.unwrap_or_else(|| "list".to_string()),
            want_size: size.and_then(|s| s.parse().ok()),
            min_total_ns: num(min_ms, 200) * 1_000_000,
            fixed_reps: num(reps, 0),
            id: String::new(),
            size: 0,
            ops: 0,
            reps: 0,
            min_ns: u64::MAX,
            total_ns: 0,
            t0: Instant::now(),
            check: 0,
            warm: false,
        }
    }

    pub fn want(&mut self, id: &str, size: u64) -> bool {
        if self.want_id == "list" {
            println!("{},{}", id, size);
            return false;
        }
        if self.want_id != "all" && self.want_id != id {
            return false;
        }
        if self.want_size.is_some_and(|s| s != size) {
            return false;
        }
        self.id = id.to_string();
        self.size = size;
        true
    }

    pub fn begin(&mut self, ops_per_rep: u64) {
        self.ops = ops_per_rep;
        self.reps = 0;
        self.min_ns = u64::MAX;
        self.total_ns = 0;
        self.check = 0;
        self.warm = false;
    }

    pub fn next(&mut self) -> bool {
        if !self.warm {
            return true;
        }
        if self.fixed_reps != 0 {
            return self.reps < self.fixed_reps;
        }
        self.reps < 3 || (self.total_ns < self.min_total_ns && self.reps < 100_000_000)
    }

    #[inline(always)]
    pub fn tic(&mut self) {
        self.t0 = Instant::now();
    }

    #[inline(always)]
    pub fn toc(&mut self, check: u64) {
        let dt = self.t0.elapsed().as_nanos() as u64;
        self.check = check;
        if !self.warm {
            self.warm = true;
            return;
        }
        self.reps += 1;
        self.total_ns += dt;
        if dt < self.min_ns {
            self.min_ns = dt;
        }
    }

    pub fn end(&mut self) {
        println!("{},{},{:.4},{}", self.id, self.size, self.min_ns as f64 / self.ops as f64, self.reps);
        eprintln!("check,{},{},{:016x},{}", self.id, self.size, self.check, self.ops);
    }

    // A row this program cannot run: the cell stays empty in the report.
    pub fn skip(&mut self) {
        println!("{},{},nan,0", self.id, self.size);
    }
}

// xorshift64 (13, 7, 17), seeded alike in every language.
pub const SEED: u64 = 0x9E3779B97F4A7C15;
pub struct Rng {
    s: u64,
}
impl Rng {
    pub fn new() -> Rng {
        Rng { s: SEED }
    }
    #[inline(always)]
    pub fn next(&mut self) -> u64 {
        self.s ^= self.s << 13;
        self.s ^= self.s >> 7;
        self.s ^= self.s << 17;
        self.s
    }
    // Uniform in [0, n) for n < 2^32, with no division.
    #[inline(always)]
    pub fn below(&mut self, n: u64) -> u64 {
        ((self.next() >> 32) * n) >> 32
    }
    pub fn letters(&mut self, len: usize, alphabet: u64) -> String {
        (0..len).map(|_| (b'a' + self.below(alphabet) as u8) as char).collect()
    }
}

// The "fast hasher" of the rows that name one; cpp/bench.h has the same.
pub const K0: u64 = 0x2D358DCCAA6C78A5;
pub const K1: u64 = 0x8BB84B93962EACC9;
#[inline(always)]
pub fn fold(a: u64, b: u64) -> u64 {
    let m = (a as u128) * (b as u128);
    (m as u64) ^ ((m >> 64) as u64)
}
#[inline(always)]
fn read64(p: &[u8]) -> u64 {
    u64::from_le_bytes(p[..8].try_into().unwrap())
}
#[inline(always)]
pub fn fast_hash_u64(x: u64) -> u64 {
    fold(x ^ K0, K1)
}
#[inline]
pub fn fast_hash_bytes(mut p: &[u8]) -> u64 {
    let mut h = K0 ^ p.len() as u64;
    if p.len() >= 32 {
        let (mut a, mut b) = (h, h);
        while p.len() >= 32 {
            a = fold(read64(p) ^ K0, read64(&p[8..]) ^ a);
            b = fold(read64(&p[16..]) ^ K1, read64(&p[24..]) ^ b);
            p = &p[32..];
        }
        h = a ^ b;
    }
    while p.len() >= 8 {
        h = fold(h ^ read64(p), K1);
        p = &p[8..];
    }
    if !p.is_empty() {
        let mut w = [0u8; 8];
        w[..p.len()].copy_from_slice(p);
        h = fold(h ^ u64::from_le_bytes(w), K1);
    }
    fold(h, K0)
}

// The fast hasher behind `std::hash::Hasher`, for HashMap and HashSet. A u64
// key hashes as fast_hash_u64, a str key as fast_hash_bytes of its bytes (the
// 0xFF byte `str` appends is dropped, so the value matches the C++ side).
#[derive(Default)]
pub struct FastHasher {
    h: u64,
}
impl Hasher for FastHasher {
    #[inline(always)]
    fn finish(&self) -> u64 {
        self.h
    }
    #[inline(always)]
    fn write(&mut self, bytes: &[u8]) {
        self.h = fast_hash_bytes(bytes);
    }
    #[inline(always)]
    fn write_u64(&mut self, x: u64) {
        self.h = fast_hash_u64(x);
    }
    #[inline(always)]
    fn write_u8(&mut self, _: u8) {}
}
pub type FastBuild = BuildHasherDefault<FastHasher>;
