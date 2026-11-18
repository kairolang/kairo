import std::iter::*
import std::io

pub static pulls: i64 = 0
pub static overruns: i64 = 0
pub static failed: i32 = 0
pub static each_acc: u64 = 0

pub fn scramble(x: u64) -> u64 {
    var z = x + 0x9E3779B97F4A7C15u64
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9u64
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBu64
    return z ^ (z >> 31)
}

/// Yields `n` values in [0, 100) drawn from `seed`, counting every pull and
/// every pull made after the end.
pub class Source {
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
pub class Deck {
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
pub class Span {
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

pub fn add1(x: i64) -> i64 = x + 1
pub fn third(x: *const i64) -> bool = *x % 3 == 0
pub fn below70(x: *const i64) -> bool = *x < 70
pub fn below30(x: *const i64) -> bool = *x < 30
pub fn above90(x: *const i64) -> bool = *x > 90
pub fn half_even(x: i64) -> i64? {
    if x % 2 == 0 {
        return x / 2
    }

    return null
}
pub fn spread(x: i64) -> Span = Span(x, x + x % 4)
pub fn spread_two(x: i64) -> Iter<Take<Span>> = iter(Span(x, x + 5)).take(2)
pub fn weigh(e: (usize, i64)) -> i64 = (e.0 as i64) * 1000 + e.1
pub fn pair_sum(e: (i64, i64)) -> i64 = e.0 * 100 + e.1
pub fn mix(acc: u64, x: i64) -> u64 = scramble(acc ^ (x as u64))
pub fn larger(a: i64, b: i64) -> i64 = if a > b => a else => b - a
pub fn note(x: i64) {
    each_acc = scramble(each_acc ^ (x as u64))
}

pub fn digest_of(const v: [i64]) -> u64 {
    var d: u64 = v.size() as u64
    for var i: usize = 0; i < v.size(); i += 1 {
        d = mix(d, v[i])
    }

    return d
}

pub const CONSUMERS: i32 = 16

/// The consumer `which`, written over `next` alone.
pub fn <I impl Iterator> by_next(it: Iter<I>, which: i32, p: usize) -> u64 requires __builtin_is_same<I::Item, i64>() {
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

pub fn or_none(x: i64?) -> u64 {
    return if x? => unwrap!(x) as u64 else => 12345
}

pub fn index_or_none(x: usize?) -> u64 {
    return if x? => unwrap!(x) as u64 else => 12345
}

pub fn judge(const label: string, seed: u64, which: i32, p: usize, pre: usize, got: u64, want: u64, got_pulls: i64, want_pulls: i64) {
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
pub macro check!(label, chain) {
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

pub fn data(seed: u64, n: i64) -> [i64] {
    var v: [i64]
    var s = seed
    for var i: i64 = 0; i < n; i += 1 {
        s = scramble(s)
        v.push((s % 100) as i64)
    }

    return v
}

pub fn counted(n: i64) -> yield i64 {
    for var i: i64 = 0; i < n; i += 1 {
        pulls += 1
        yield (i * 37) % 100
    }
}
