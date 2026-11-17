// Hasher rows (ops.toml, group "hash"). `_std` is the hasher HashMap uses by
// default (SipHash-1-3 with per-process keys, through RandomState); `_fast` is
// bench.rs's fast hasher. A `_std` checksum counts the calls; a `_fast`
// checksum is the hashes themselves.
#[path = "bench.rs"]
mod bench;
use bench::{black_box, fast_hash_bytes, fast_hash_u64, Bench, Rng};
use std::collections::hash_map::RandomState;
use std::hash::BuildHasher;

fn u64(b: &mut Bench, fast: bool) {
    let ops = 1u64 << 20;
    let state = RandomState::new();
    b.begin(ops);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        if fast {
            for i in 0..ops {
                acc = acc.wrapping_add(fast_hash_u64(black_box(i)));
            }
        } else {
            for i in 0..ops {
                acc = acc.wrapping_add(state.hash_one(black_box(i)));
            }
        }
        black_box(acc);
        b.toc(if fast { acc } else { ops });
    }
    b.end();
}

fn bytes(b: &mut Bench, len: u64, fast: bool) {
    let keys = 256u64;
    let passes = (1u64 << 22) / (keys * len);
    let mut rng = Rng::new();
    let k: Vec<String> = (0..keys).map(|_| rng.letters(len as usize, 26)).collect();
    let state = RandomState::new();
    b.begin(keys * passes);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        for _ in 0..passes {
            let k = black_box(&k);
            if fast {
                for s in k {
                    acc = acc.wrapping_add(fast_hash_bytes(s.as_bytes()));
                }
            } else {
                for s in k {
                    acc = acc.wrapping_add(state.hash_one(s.as_str()));
                }
            }
        }
        black_box(acc);
        b.toc(if fast { acc } else { keys * passes });
    }
    b.end();
}

fn main() {
    let b = &mut Bench::init();
    if b.want("hash.u64_std", 8) {
        u64(b, false);
    }
    if b.want("hash.u64_fast", 8) {
        u64(b, true);
    }
    for n in [8, 16, 64, 1024] {
        if b.want("hash.bytes_std", n) {
            bytes(b, n, false);
        }
        if b.want("hash.bytes_fast", n) {
            bytes(b, n, true);
        }
    }
}
