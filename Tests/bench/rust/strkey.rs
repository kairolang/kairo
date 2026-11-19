// Strings as keys, in isolation: the twin of kairo/strkey.k (which has the
// row list). Run by hand; no rows in ops.toml.
#[path = "bench.rs"]
mod bench;
use bench::{black_box, Bench, Rng};

fn order(b: &mut Bench, len: u64, shared: bool) {
    let (pairs, passes) = (1024u64, 64u64);
    let mut rng = Rng::new();
    let (mut x, mut y) = (Vec::new(), Vec::new());
    for _ in 0..pairs {
        let s = rng.letters(len as usize, 26);
        let mut t = rng.letters(len as usize, 26);
        if shared {
            t = s.clone();
            t.pop();
            t.push((b'a' + rng.below(26) as u8) as char);
        }
        x.push(s);
        y.push(t);
    }
    b.begin(pairs * passes);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        for _ in 0..passes {
            let (x, y) = (black_box(&x), black_box(&y));
            for i in 0..pairs as usize {
                acc += (x[i] < y[i]) as u64;
            }
        }
        b.toc(acc);
    }
    b.end();
}

fn eq(b: &mut Bench, len: u64) {
    let (pairs, passes) = (1024u64, 64u64);
    let mut rng = Rng::new();
    let (mut x, mut y) = (Vec::new(), Vec::new());
    for i in 0..pairs {
        let s = rng.letters(len as usize, 26);
        let mut t = s.clone();
        if i & 1 == 1 {
            t.pop();
            t.push('Z');
        }
        x.push(s);
        y.push(t);
    }
    b.begin(pairs * passes);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        for _ in 0..passes {
            let (x, y) = (black_box(&x), black_box(&y));
            for i in 0..pairs as usize {
                acc += (x[i] == y[i]) as u64;
            }
        }
        b.toc(acc);
    }
    b.end();
}

fn main() {
    let b = &mut Bench::init();
    for n in [3, 6, 8, 12, 16, 24, 32, 64] {
        if b.want("strkey.order", n) {
            order(b, n, false);
        }
        if b.want("strkey.order_prefix", n) {
            order(b, n, true);
        }
        if b.want("strkey.eq", n) {
            eq(b, n);
        }
    }
}
