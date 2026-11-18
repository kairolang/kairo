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

    // A slice's `iter()`: its length is known, so `take` cuts it and `skip`
    // and `step_by` count from it; it runs from either end.
    var v = data(seed, n)
    var w = data(s2, m)
    var vs: [const i64;] = v
    var ws: [const i64;] = w
    check!("slice", iter(vs.iter()).copied())
    check!("vector", iter(v.iter()).copied().map<i64>(add1))
    check!("slice.take.rev", iter(vs.iter()).copied().take(k).rev())
    check!("slice.skip.rev", iter(vs.iter()).copied().skip(k).rev())
    check!("slice.enumerate.rev", iter(vs.iter()).copied().enumerate().rev().map<i64>(weigh))
    check!("slice.zip.rev", iter(vs.iter()).copied().zip(iter(ws.iter()).copied()).rev().map<i64>(pair_sum))
    check!("slice.chain(chain).rev", iter(vs.iter()).copied().chain(iter(ws.iter()).copied().take(k)).rev())
    check!("slice.rev.copied", iter(vs.iter()).rev().take(k).copied())
    check!("slice.rev", iter(vs.iter()).copied().rev())
    check!("slice.rev.rev", iter(vs.iter()).copied().rev().rev())
    check!("slice.map.rev", iter(vs.iter()).copied().map<i64>(add1).rev())
    check!("slice.filter.rev", iter(vs.iter()).copied().filter(third).rev())
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
