// Allocation rows (ops.toml, group "alloc"): the global allocator through
// std::alloc, and Box for the object rows.
#[path = "bench.rs"]
mod bench;
use bench::{black_box, Bench};
use std::alloc::{alloc, dealloc, realloc, Layout};

fn pair(b: &mut Bench, size: u64) {
    let ops: u64 = if size > 65536 { 2000 } else { 200000 };
    b.begin(ops);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        for i in 0..ops {
            let n = black_box(size) as usize;
            let layout = Layout::from_size_align(n, 8).unwrap();
            unsafe {
                let p = alloc(layout);
                *p = i as u8;
                black_box(p);
                acc += *p as u64;
                dealloc(p, layout);
            }
        }
        b.toc(acc);
    }
    b.end();
}

struct Obj16 {
    a: u64,
    b: u64,
}
struct Obj64 {
    a: u64,
    b: u64,
    _pad: [u64; 6],
}

fn object16(b: &mut Bench) {
    let ops = 200000u64;
    b.begin(ops);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        for i in 0..ops {
            let p = black_box(Box::new(Obj16 { a: i, b: 2 }));
            acc += p.a + p.b;
            drop(p);
        }
        b.toc(acc);
    }
    b.end();
}

fn object64(b: &mut Bench) {
    let ops = 200000u64;
    b.begin(ops);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        for i in 0..ops {
            let p = black_box(Box::new(Obj64 { a: i, b: 2, _pad: [0; 6] }));
            acc += p.a + p.b;
            drop(p);
        }
        b.toc(acc);
    }
    b.end();
}

fn batch(b: &mut Bench, size: u64) {
    let (live, rounds) = (1024usize, 200u64);
    let mut slot = [std::ptr::null_mut::<u8>(); 1024];
    b.begin(live as u64 * rounds);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        for _ in 0..rounds {
            let n = black_box(size) as usize;
            let layout = Layout::from_size_align(n, 8).unwrap();
            unsafe {
                for (k, s) in slot.iter_mut().enumerate() {
                    let p = alloc(layout);
                    *p = k as u8;
                    *s = p;
                }
                black_box(&mut slot);
                for s in slot.iter() {
                    acc += **s as u64;
                    dealloc(*s, layout);
                }
            }
        }
        b.toc(acc);
    }
    b.end();
}

fn grow(b: &mut Bench, size: u64) {
    let chains = 500u64;
    let mut steps = 0u64;
    let mut n = 16u64;
    while n < size {
        steps += 1;
        n *= 2;
    }
    b.begin(chains * steps);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        for c in 0..chains {
            // 16 bytes, as a value the optimizer knows nothing about.
            let mut n = 16 + (black_box(c) >> 60) as usize;
            unsafe {
                let mut p = alloc(Layout::from_size_align(n, 8).unwrap());
                *p = 1;
                while n < size as usize {
                    p = realloc(p, Layout::from_size_align(n, 8).unwrap(), n * 2);
                    *p.add(n) = 1;
                    black_box(p);
                    acc += *p as u64 + *p.add(n) as u64;
                    n *= 2;
                }
                dealloc(p, Layout::from_size_align(n, 8).unwrap());
            }
        }
        b.toc(acc);
    }
    b.end();
}

fn main() {
    let b = &mut Bench::init();
    for n in [16, 256, 4096, 1048576] {
        if b.want("alloc.pair", n) {
            pair(b, n);
        }
    }
    if b.want("alloc.object", 16) {
        object16(b);
    }
    if b.want("alloc.object", 64) {
        object64(b);
    }
    for n in [16, 256] {
        if b.want("alloc.batch", n) {
            batch(b, n);
        }
    }
    if b.want("alloc.grow", 1048576) {
        grow(b, 1048576);
    }
}
