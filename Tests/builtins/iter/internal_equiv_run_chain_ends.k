// Every consumer gives what a `next` loop over the same chain gives, and
// pulls the same number of items from its source to get it. Each chain
// below is built twice from one seed: `by_next` consumes it by calling
// `next` and nothing else, `by_run` calls the consumer. The two digests and
// the two pull counts must agree, for every consumer (those that stop early
// included), with zero to three items pulled by hand before the consumer
// runs. inputs, lengths and the `take` / `skip` / `step_by` arguments come
// from a seeded generator; a failure prints the chain, the consumer and the
// seed.

import std::iter::*
import std::io
import self::inputs::internal_equiv::*

/// Every chain, for one seed, one consumer and one count of items pulled by
/// hand. `n` and `m` are source lengths; `k` and `j` the adapter arguments.
fn round(seed: u64, which: i32, pre: usize) {
    var r = scramble(seed)
    var n = (r % 41) as i64
    var m = ((r >> 8) % 23) as i64
    var k = ((r >> 16) % 13) as usize
    var j = ((r >> 24) % 5) as usize
    var p = ((r >> 32) % 9) as usize
    var s2 = seed ^ 0xABCDu64

    // An adapter that ends its own run, under one that goes on to a second
    // part: the second part runs, and only after the first has ended.
    check!("take.chain", iter(Source(seed, n)).take(k).chain(Source(s2, m)))
    check!("take_while.chain", iter(Source(seed, n)).take_while(below70).chain(Source(s2, m)))
    check!("zip.chain", iter(Source(seed, n)).zip(Source(s2, m)).map<i64>(pair_sum).chain(Source(s2, m)))
    check!("step_by.chain", iter(Source(seed, n)).step_by(j + 1).chain(Source(s2, m)))
    check!("flat_map(take)", iter(Source(seed, n)).flat_map<Iter<Take<Span>>>(spread_two))
    check!("chain.flat_map", iter(Source(seed, n)).filter(third).chain(Source(s2, m)).flat_map<Span>(spread))

    // Adapters that go on with their inner iterator after ending a run of
    // their own over it.
    check!("skip.take_while.skip_while.step_by", iter(Source(seed, n)).skip(k).take_while(below70).skip_while(below30).step_by(j + 1))
    check!("flat_map.skip", iter(Source(seed, n)).flat_map<Span>(spread).skip(k))
    check!("chain.skip_while", iter(Source(seed, n)).chain(Source(s2, m)).skip_while(below30))
    check!("take.skip", iter(Source(seed, n)).map<i64>(add1).filter(third).take(k).skip(j))
    check!("chain.take", iter(Source(seed, n)).chain(Source(s2, m)).take(k + 20))
    check!("take.zip", iter(Source(seed, n)).take(k).zip(Source(s2, m)).map<i64>(pair_sum))
    check!("peekable.skip.take", iter(Source(seed, n)).peekable().skip(j).take(k))
    check!("enumerate.skip", iter(Source(seed, n)).enumerate().skip(k).map<i64>(weigh))
}

fn main() -> i32 {
    var rounds: u64 = 0
    for var seed: u64 = 1; seed <= 60; seed += 1 {
        for var which: i32 = 0; which < CONSUMERS; which += 1 {
            for var pre: usize = 0; pre < 4; pre += 1 {
                round(seed * 0x1234567u64, which, pre)
                rounds += 1
            }
        }
    }

    if failed != 0 {
        io::println(f"{failed} of the comparisons failed")
        return 1
    }

    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -f %t.O2.exe
// RUN: rm -rf %t.d
// RUN: %kairo_new -O2 %s -o %t.O2.exe --cache-dir %t.d
// RUN: %t.O2.exe
