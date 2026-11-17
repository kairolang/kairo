// Every consumer gives what a `next` loop over the same chain gives, and
// pulls the same number of items from its source to get it. Each chain
// below is built twice from one seed: `by_next` consumes it by calling
// `next` and nothing else, `by_run` calls the consumer. The two digests and
// the two pull counts must agree, for every consumer (those that stop early
// included), with zero to three items pulled by hand before the consumer
// runs. Inputs, lengths and the `take` / `skip` / `step_by` arguments come
// from a seeded generator; a failure prints the chain, the consumer and the
// seed.

import std::iter::*
import std::io

var pulls: i64 = 0
var overruns: i64 = 0
var failed: i32 = 0
var each_acc: u64 = 0

fn scramble(x: u64) -> u64 {
    var z = x + 0x9E3779B97F4A7C15u64
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9u64
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBu64
    return z ^ (z >> 31)
}

/// Yields `n` values in [0, 100) drawn from `seed`, counting every pull and
/// every pull made after the end.
class Source {
    var state: u64
    var left:  i64
    var ended: bool

    pub fn Source(self, seed: u64, n: i64) {
        self.state = seed
        self.left  = n
        self.ended = false
    }
}

extend Source impl Iterator {
    type Item = i64
    fn next(self) -> i64? {
        pulls += 1
        if self.ended {
            overruns += 1
        }

        if self.left == 0 {
            self.ended = true
            return null
        }

        self.left  -= 1
        self.state  = scramble(self.state)
        return (self.state % 100) as i64
    }
}

/// `n` values in [0, 100) drawn from `seed`, read from either end, with
/// their count. Every pull from either end is counted, and every pull made
/// after the end.
class Deck {
    var items: [i64]
    var lo:    usize
    var hi:    usize
    var ended: bool

    pub fn Deck(self, seed: u64, n: i64) {
        self.lo    = 0
        self.hi    = n as usize
        self.ended = false
        var s = seed
        for var i: i64 = 0; i < n; i += 1 {
            s = scramble(s)
            self.items.push((s % 100) as i64)
        }
    }
}

extend Deck impl DoubleEnded {
    type Item = i64
    fn next(self) -> i64? {
        pulls += 1
        if self.ended {
            overruns += 1
        }

        if self.lo == self.hi {
            self.ended = true
            return null
        }

        self.lo += 1
        return self.items[self.lo - 1]
    }
    fn next_back(self) -> i64? {
        pulls += 1
        if self.ended {
            overruns += 1
        }

        if self.lo == self.hi {
            self.ended = true
            return null
        }

        self.hi -= 1
        return self.items[self.hi]
    }
}

extend Deck impl ExactSize {
    fn remaining(const self) -> usize {
        return self.hi - self.lo
    }
}

/// Counts from `lo` up to `hi` (exclusive).
class Span {
    var lo: i64
    var hi: i64

    pub fn Span(self, lo: i64, hi: i64) {
        self.lo = lo
        self.hi = hi
    }
}

extend Span impl Iterator {
    type Item = i64
    fn next(self) -> i64? {
        if self.lo == self.hi {
            return null
        }

        self.lo += 1
        return self.lo - 1
    }
}

fn add1(x: i64) -> i64 = x + 1
fn third(x: *const i64) -> bool = *x % 3 == 0
fn below70(x: *const i64) -> bool = *x < 70
fn below30(x: *const i64) -> bool = *x < 30
fn above90(x: *const i64) -> bool = *x > 90
fn half_even(x: i64) -> i64? {
    if x % 2 == 0 {
        return x / 2
    }

    return null
}
fn spread(x: i64) -> Span = Span(x, x + x % 4)
fn spread_two(x: i64) -> Iter<Take<Span>> = iter(Span(x, x + 5)).take(2)
fn weigh(e: (usize, i64)) -> i64 = (e.0 as i64) * 1000 + e.1
fn pair_sum(e: (i64, i64)) -> i64 = e.0 * 100 + e.1
fn mix(acc: u64, x: i64) -> u64 = scramble(acc ^ (x as u64))
fn larger(a: i64, b: i64) -> i64 = if a > b => a else => b - a
fn note(x: i64) {
    each_acc = scramble(each_acc ^ (x as u64))
}

fn digest_of(const v: [i64]) -> u64 {
    var d: u64 = v.size() as u64
    for var i: usize = 0; i < v.size(); i += 1 {
        d = mix(d, v[i])
    }

    return d
}

const CONSUMERS: i32 = 16

/// The consumer `which`, written over `next` alone.
fn <I impl Iterator> by_next(it: Iter<I>, which: i32, p: usize) -> u64 requires __builtin_is_same<I::Item, i64>() {
    var items: [i64]
    var stop_at: usize = 0xFFFFFFFF
    // The consumers that stop early stop pulling at the item that decides
    // them.
    loop {
        if which == 4 && items.size() == p + 1 {
            break
        }

        var x = it.next()
        if !x? {
            break
        }

        var v: i64 = unwrap!(x)
        items.push(v)
        if (which == 5 || which == 6 || which == 7) && above90(const &v) {
            stop_at = items.size() - 1
            break
        }

        if which == 8 && !below70(const &v) {
            stop_at = items.size() - 1
            break
        }
    }

    var n = items.size()
    if which == 0 {
        var acc: u64 = 7
        for var i: usize = 0; i < n; i += 1 {
            acc = mix(acc, items[i])
        }

        return acc
    }

    if which == 1 {
        return n as u64
    }

    if which == 2 {
        return if n == 0 => 12345 else => items[n - 1] as u64
    }

    if which == 3 {
        if n < 2 {
            return if n == 0 => 12345 else => items[0] as u64
        }

        var acc = items[0]
        for var i: usize = 1; i < n; i += 1 {
            acc = larger(acc, items[i])
        }

        return acc as u64
    }

    if which == 4 {
        return if n == p + 1 => items[p] as u64 else => 12345
    }

    if which == 5 {
        return if stop_at != 0xFFFFFFFF => items[stop_at] as u64 else => 12345
    }

    if which == 6 {
        return if stop_at != 0xFFFFFFFF => stop_at as u64 else => 12345
    }

    if which == 7 {
        return if stop_at != 0xFFFFFFFF => 1 else => 0
    }

    if which == 8 {
        return if stop_at != 0xFFFFFFFF => 0 else => 1
    }

    if which == 9 {
        var acc: u64 = 0
        for var i: usize = 0; i < n; i += 1 {
            acc = scramble(acc ^ (items[i] as u64))
        }

        return acc
    }

    if which == 10 {
        var sum: i64 = 0
        for var i: usize = 0; i < n; i += 1 {
            sum += items[i]
        }

        return sum as u64
    }

    if which == 11 || which == 12 {
        if n == 0 {
            return 12345
        }

        var best = items[0]
        for var i: usize = 1; i < n; i += 1 {
            if which == 11 && items[i] < best {
                best = items[i]
            }

            if which == 12 && items[i] >= best {
                best = items[i]
            }
        }

        return best as u64
    }

    if which == 13 {
        return digest_of(items)
    }

    if which == 14 {
        var yes: [i64]
        var no:  [i64]
        for var i: usize = 0; i < n; i += 1 {
            if third(const &items[i]) {
                yes.push(items[i])
            } else {
                no.push(items[i])
            }
        }

        return digest_of(yes) ^ (digest_of(no) << 1)
    }

    items.sort()
    return digest_of(items)
}

fn or_none(x: i64?) -> u64 {
    return if x? => unwrap!(x) as u64 else => 12345
}

fn index_or_none(x: usize?) -> u64 {
    return if x? => unwrap!(x) as u64 else => 12345
}

fn judge(const label: string, seed: u64, which: i32, p: usize, pre: usize, got: u64, want: u64, got_pulls: i64, want_pulls: i64) {
    if got != want || got_pulls != want_pulls || overruns != 0 {
        failed += 1
        if failed < 20 {
            io::println(f"FAILED {label}: consumer {which}, seed {seed}, p {p}, pre {pre}: got {got} pulling {got_pulls}, expected {want} pulling {want_pulls}, overruns {overruns}")
        }
    }
}

/// Runs the consumer `which` both ways over two builds of `chain`, each with
/// `pre` items pulled by hand first. A macro, so that each consumer is
/// called on the chain's own type: the names `seed`, `which`, `p` and `pre`
/// are the caller's.
macro check!(label, chain) {
    {
        pulls    = 0
        overruns = 0
        var a = chain
        var b = chain
        var live = true
        var head: u64 = 0
        for var i: usize = 0; i < pre; i += 1 {
            var x? = a.next()
            var y? = b.next()
            if !x? || !y? {
                // An ended chain is not asked again by either path.
                live = x? || y?
                head = if live => 1 else => 0
                break
            }

            if unwrap!(x) != unwrap!(y) {
                head = 1
            }
        }

        if head != 0 {
            judge(label, seed, which, p, pre, 1, 0, 0, 0)
        } else if live {
            pulls = 0
            var want = by_next(move(a), which, p)
            var want_pulls = pulls
            pulls = 0
            var got: u64 = 0
            if which == 0 {
                got = b.fold<u64>(7, mix)
            } else if which == 1 {
                got = b.count() as u64
            } else if which == 2 {
                got = or_none(b.last())
            } else if which == 3 {
                got = or_none(b.reduce(larger))
            } else if which == 4 {
                got = or_none(b.nth(p))
            } else if which == 5 {
                got = or_none(b.find(above90))
            } else if which == 6 {
                got = index_or_none(b.position(above90))
            } else if which == 7 {
                got = if b.any(above90) => 1 else => 0
            } else if which == 8 {
                got = if b.all(below70) => 1 else => 0
            } else if which == 9 {
                each_acc = 0
                b.for_each(note)
                got = each_acc
            } else if which == 10 {
                var sum: i64 = b.sum()
                got = sum as u64
            } else if which == 11 {
                got = or_none(b.min())
            } else if which == 12 {
                got = or_none(b.max())
            } else if which == 13 {
                var all = b.collect<[i64]>()
                got = digest_of(all)
            } else if which == 14 {
                var parts = b.partition(third)
                got = digest_of(parts.0) ^ (digest_of(parts.1) << 1)
            } else {
                var all = b.sorted()
                got = digest_of(all)
            }

            judge(label, seed, which, p, pre, got, want, pulls, want_pulls)
        }
    }
}

fn data(seed: u64, n: i64) -> [i64] {
    var v: [i64]
    var s = seed
    for var i: i64 = 0; i < n; i += 1 {
        s = scramble(s)
        v.push((s % 100) as i64)
    }

    return v
}

fn counted(n: i64) -> yield i64 {
    for var i: i64 = 0; i < n; i += 1 {
        pulls += 1
        yield (i * 37) % 100
    }
}

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

    check!("map", iter(Source(seed, n)).map<i64>(add1))
    check!("filter", iter(Source(seed, n)).filter(third))
    check!("filter_map", iter(Source(seed, n)).filter_map<i64>(half_even))
    check!("flat_map", iter(Source(seed, n)).flat_map<Span>(spread))
    check!("enumerate", iter(Source(seed, n)).enumerate().map<i64>(weigh))
    check!("zip", iter(Source(seed, n)).zip(Source(s2, m)).map<i64>(pair_sum))
    check!("chain", iter(Source(seed, n)).chain(Source(s2, m)))
    check!("take", iter(Source(seed, n)).take(k))
    check!("skip", iter(Source(seed, n)).skip(k))
    check!("take_while", iter(Source(seed, n)).take_while(below70))
    check!("skip_while", iter(Source(seed, n)).skip_while(below30))
    check!("step_by", iter(Source(seed, n)).step_by(j + 1))
    check!("peekable", iter(Source(seed, n)).peekable())

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

    // A source with two ends and a count that counts its pulls: what an
    // adapter drops from the back to reach its last item is pulled the same
    // way by both paths.
    check!("deck.rev", iter(Deck(seed, n)).rev())
    check!("deck.take.rev", iter(Deck(seed, n)).take(k).rev())
    check!("deck.take(0).rev", iter(Deck(seed, n)).take(0).rev())
    check!("deck.skip.rev", iter(Deck(seed, n)).skip(k).rev())
    check!("deck.enumerate.rev", iter(Deck(seed, n)).enumerate().rev().map<i64>(weigh))
    check!("deck.zip.rev", iter(Deck(seed, n)).zip(Deck(s2, m)).rev().map<i64>(pair_sum))
    check!("deck.rev.take", iter(Deck(seed, n)).rev().take(k))
    check!("deck.map.take.rev", iter(Deck(seed, n)).map<i64>(add1).take(k).rev())
    check!("deck.take.rev.skip", iter(Deck(seed, n)).take(k + 2).rev().skip(j))
    check!("deck.skip.take.rev.take_while", iter(Deck(seed, n)).skip(j).take(k).rev().take_while(below70))

    // A generator, which counts its own resumes.
    check!("generator", iter(counted(n)).map<i64>(add1).filter(third))
    check!("generator.take", iter(counted(n)).take(k))
    check!("generator.skip.step_by", iter(counted(n)).skip(k).step_by(j + 1))

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
    check!("slice.take", iter(vs.iter()).copied().map<i64>(add1).take(k))
    check!("slice.rev.take", iter(vs.iter()).copied().rev().take(k))
    check!("slice.enumerate.take", iter(vs.iter()).copied().enumerate().take(k).map<i64>(weigh))
    check!("slice.skip.take", iter(vs.iter()).copied().skip(j).take(k))
    check!("slice.take.take", iter(vs.iter()).copied().take(k + 3).take(k))
    check!("slice.step_by", iter(vs.iter()).copied().step_by(j + 1))
    check!("slice.rev.skip", iter(vs.iter()).copied().rev().skip(k))
    check!("slice.zip", iter(vs.iter()).copied().zip(iter(ws.iter()).copied()).map<i64>(pair_sum))
    check!("slice.zip.take", iter(vs.iter()).copied().zip(iter(ws.iter()).copied()).take(k).map<i64>(pair_sum))
    check!("slice.chain", iter(vs.iter()).copied().chain(iter(ws.iter()).copied()))
    check!("slice.chain.step_by", iter(vs.iter()).copied().chain(iter(ws.iter()).copied()).step_by(j + 1))
    check!("slice.peekable.take", iter(vs.iter()).copied().peekable().take(k))
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
// RUN: rm -f %t.exe %t.O2.exe
// RUN: rm -rf %t.d
// RUN: %kairo_new -O2 %s -o %t.O2.exe --cache-dir %t.d
// RUN: %t.O2.exe
