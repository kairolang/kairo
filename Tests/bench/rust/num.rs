// Number text rows (ops.toml, group "num"): std formatting (`write!` with
// `{}`) and `str::parse`.
#[path = "bench.rs"]
mod bench;
use bench::{black_box, Bench, Rng};
use std::fmt::Write;

const COUNT: u64 = 4096;
const PASSES: u64 = 64;

fn integers(digits: u64) -> Vec<u64> {
    let mut rng = Rng::new();
    (0..COUNT).map(|_| if digits == 4 { rng.below(10000) } else { rng.next() }).collect()
}

// In [0, 10^6), with a full 53-bit significand.
fn doubles() -> Vec<f64> {
    let mut rng = Rng::new();
    (0..COUNT).map(|_| (rng.next() >> 11) as f64 * (1.0 / 9007199254740992.0) * 1e6).collect()
}

fn to_text<T: std::fmt::Display>(b: &mut Bench, v: Vec<T>) {
    let mut s = String::new();
    b.begin(COUNT * PASSES);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        for _ in 0..PASSES {
            s.clear();
            for x in black_box(&v) {
                write!(s, "{}", x).unwrap();
            }
            acc += s.len() as u64;
        }
        b.toc(acc);
    }
    b.end();
}

fn text_to_u64(b: &mut Bench, digits: u64) {
    let text: Vec<String> = integers(digits).iter().map(|x| x.to_string()).collect();
    b.begin(COUNT * PASSES);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        for _ in 0..PASSES {
            for t in black_box(&text) {
                acc = acc.wrapping_add(t.parse::<u64>().unwrap());
            }
        }
        b.toc(acc);
    }
    b.end();
}

fn text_to_f64(b: &mut Bench) {
    let text: Vec<String> = doubles().iter().map(|x| x.to_string()).collect();
    b.begin(COUNT * PASSES);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        for _ in 0..PASSES {
            for t in black_box(&text) {
                acc = acc.wrapping_add(t.parse::<f64>().unwrap().to_bits());
            }
        }
        b.toc(acc);
    }
    b.end();
}

fn main() {
    let b = &mut Bench::init();
    for d in [4, 20] {
        if b.want("num.u64_to_text", d) {
            to_text(b, integers(d));
        }
        if b.want("num.text_to_u64", d) {
            text_to_u64(b, d);
        }
    }
    if b.want("num.f64_to_text", 17) {
        to_text(b, doubles());
    }
    if b.want("num.text_to_f64", 17) {
        text_to_f64(b);
    }
}
