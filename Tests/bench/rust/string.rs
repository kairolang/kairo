// String rows (ops.toml, group "string"): String and str.
#[path = "bench.rs"]
mod bench;
use bench::{black_box, Bench, Rng};

fn create_destroy(b: &mut Bench, len: u64) {
    let ops = 200000u64;
    let src = Rng::new().letters(len as usize, 26);
    b.begin(ops);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        for _ in 0..ops {
            let s = String::from(&src[..black_box(len as usize)]);
            black_box(s.as_ptr());
            acc += s.len() as u64;
        }
        b.toc(acc);
    }
    b.end();
}

// `push` takes a char; an ASCII one is stored as its one byte.
fn push_byte(b: &mut Bench, n: u64) {
    let mut s = String::new();
    b.begin(n);
    while b.next() {
        s = String::new();
        b.tic();
        for i in 0..n {
            s.push((b'a' + (i & 15) as u8) as char);
        }
        b.toc(s.len() as u64 + s.as_bytes()[n as usize - 1] as u64);
    }
    b.end();
    black_box(&s);
}

fn append_literal(b: &mut Bench, len: u64) {
    let ops = 100000u64;
    let mut s = String::new();
    b.begin(ops);
    while b.next() {
        s = String::new();
        b.tic();
        if len == 4 {
            for _ in 0..ops {
                s.push_str("abcd");
            }
        } else {
            for _ in 0..ops {
                s.push_str("hello, world");
            }
        }
        b.toc(s.len() as u64);
    }
    b.end();
    black_box(&s);
}

fn find(b: &mut Bench, n: u64) {
    let ops = (1u64 << 22) / n;
    let mut hay = Rng::new().letters(n as usize, 16);
    hay.pop();
    hay.push('z');
    let needle = hay[n as usize - 8..].to_string();
    b.begin(ops);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        for _ in 0..ops {
            let h: &str = black_box(hay.as_str());
            acc += h.find(black_box(needle.as_str())).unwrap() as u64;
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

// UTF-8 text of exactly n bytes: seven in ten code points are one byte, two
// are two bytes (U+00C0..U+00FF), one is three (U+2080..U+20BF).
fn utf8_text(n: u64) -> String {
    let mut rng = Rng::new();
    let mut s: Vec<u8> = Vec::new();
    while s.len() as u64 + 3 <= n {
        let kind = rng.below(10);
        if kind < 7 {
            s.push(b'a' + rng.below(26) as u8);
        } else if kind < 9 {
            s.push(0xC3);
            s.push(0x80 + rng.below(64) as u8);
        } else {
            s.push(0xE2);
            s.push(0x82);
            s.push(0x80 + rng.below(64) as u8);
        }
    }
    while (s.len() as u64) < n {
        s.push(b'x');
    }
    String::from_utf8(s).unwrap()
}

fn codepoints(b: &mut Bench, n: u64) {
    let passes = (1u64 << 22) / n;
    let s = utf8_text(n);
    b.begin(n * passes);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        for _ in 0..passes {
            acc += black_box(s.as_str()).chars().count() as u64;
        }
        b.toc(acc);
    }
    b.end();
}

fn main() {
    let b = &mut Bench::init();
    for n in [0, 8, 32, 256] {
        if b.want("string.create_destroy", n) {
            create_destroy(b, n);
        }
    }
    if b.want("string.push_byte", 1048576) {
        push_byte(b, 1048576);
    }
    for n in [4, 12] {
        if b.want("string.append_literal", n) {
            append_literal(b, n);
        }
    }
    for n in [64, 4096, 1048576] {
        if b.want("string.find", n) {
            find(b, n);
        }
    }
    for n in [8, 16] {
        if b.want("string.eq", n) {
            eq(b, n);
        }
    }
    for n in [4096, 1048576] {
        if b.want("string.codepoints", n) {
            codepoints(b, n);
        }
    }
    // The count is not stored by String: no counterpart to a cached read.
    for n in [4096, 1048576] {
        if b.want("string.codepoints_cached", n) {
            b.skip();
        }
    }
}
