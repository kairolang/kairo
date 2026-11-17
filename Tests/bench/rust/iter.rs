// Iterator chain rows (ops.toml, group "iter"): std iterator adapters, and
// beside each chain the loop a person would write by hand (`_loop`).
#[path = "bench.rs"]
mod bench;
use bench::{black_box, Bench, Rng};

fn triple(x: i32) -> i32 {
    x * 3
}
fn is_even(x: &i32) -> bool {
    x & 1 == 0
}

// Values in [-1000, 1000]: no sum below leaves i32.
fn input(n: u64) -> Vec<i32> {
    let mut rng = Rng::new();
    (0..n).map(|_| rng.below(2001) as i32 - 1000).collect()
}

#[derive(Clone, Copy, PartialEq)]
enum Chain {
    MapFilterSum,
    EnumerateTake,
    RevTakeWhile,
    CollectMap,
}

fn chain(which: Chain, v: &[i32]) -> u64 {
    match which {
        Chain::MapFilterSum => v.iter().copied().map(triple).filter(is_even).sum::<i32>() as i64 as u64,
        Chain::EnumerateTake => {
            v.iter().enumerate().take(v.len() / 2).map(|(i, &x)| i as i64 * x as i64).sum::<i64>() as u64
        }
        Chain::RevTakeWhile => v.iter().rev().take_while(|&&x| x != 5000).count() as u64,
        Chain::CollectMap => {
            let out: Vec<i32> = v.iter().copied().map(triple).collect();
            black_box(out.as_ptr());
            out.len() as u64 + out[out.len() - 1] as i64 as u64
        }
    }
}

fn by_hand(which: Chain, v: &[i32]) -> u64 {
    let n = v.len();
    match which {
        Chain::MapFilterSum => {
            let mut sum = 0i32;
            for i in 0..n {
                let x = v[i] * 3;
                if x & 1 == 0 {
                    sum += x;
                }
            }
            sum as i64 as u64
        }
        Chain::EnumerateTake => {
            let mut sum = 0i64;
            for i in 0..n / 2 {
                sum += i as i64 * v[i] as i64;
            }
            sum as u64
        }
        Chain::RevTakeWhile => {
            let mut i = n;
            while i != 0 && v[i - 1] != 5000 {
                i -= 1;
            }
            (n - i) as u64
        }
        Chain::CollectMap => {
            let mut out: Vec<i32> = Vec::with_capacity(n);
            for i in 0..n {
                out.push(v[i] * 3);
            }
            black_box(out.as_ptr());
            (out.len() as u64).wrapping_add(out[n - 1] as i64 as u64)
        }
    }
}

fn run(b: &mut Bench, which: Chain, hand: bool, n: u64) {
    let passes = (1u64 << 22) / n;
    let v = input(n);
    b.begin((if which == Chain::EnumerateTake { n / 2 } else { n }) * passes);
    while b.next() {
        let mut acc = 0u64;
        b.tic();
        for _ in 0..passes {
            let v: &[i32] = black_box(&v);
            acc = acc.wrapping_add(if hand { by_hand(which, v) } else { chain(which, v) });
        }
        b.toc(acc);
    }
    b.end();
}

fn main() {
    let b = &mut Bench::init();
    for n in [1000, 1000000] {
        if b.want("iter.map_filter_sum", n) {
            run(b, Chain::MapFilterSum, false, n);
        }
        if b.want("iter.map_filter_sum_loop", n) {
            run(b, Chain::MapFilterSum, true, n);
        }
        if b.want("iter.enumerate_take", n) {
            run(b, Chain::EnumerateTake, false, n);
        }
        if b.want("iter.enumerate_take_loop", n) {
            run(b, Chain::EnumerateTake, true, n);
        }
        if b.want("iter.rev_take_while_count", n) {
            run(b, Chain::RevTakeWhile, false, n);
        }
        if b.want("iter.rev_take_while_count_loop", n) {
            run(b, Chain::RevTakeWhile, true, n);
        }
        if b.want("iter.collect_map", n) {
            run(b, Chain::CollectMap, false, n);
        }
        if b.want("iter.collect_map_loop", n) {
            run(b, Chain::CollectMap, true, n);
        }
    }
}
