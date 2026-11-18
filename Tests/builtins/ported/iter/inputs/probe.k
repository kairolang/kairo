// Shared fixtures for the ported iterator tests: the check helpers, the
// element types and the counting sources.
//
// Counted is a move-only class that counts every construction, move and
// destruction and keeps a state word that catches a read of a moved-from or
// destroyed object. Fwd and Both are sources of `E::make(0) ...
// E::make(n - 1)`: every call of `next` / `next_back` is counted in PULLS and
// BACKS, the value asked for is appended to the trace (front pulls as `v`,
// back pulls as `1000 + v`), and a call made after either end returned null
// is counted in OVERRUNS. Fwd is only an Iterator; Both is also DoubleEnded
// and ExactSize.

import std::io
import std::iter::*
import builtin::base::cmp::*

pub static LIVE:     i64 = 0
pub static CTORS:    i64 = 0
pub static MOVES:    i64 = 0
pub static DTORS:    i64 = 0
pub static ERRS:     i64 = 0
pub static PULLS:    i64 = 0
pub static BACKS:    i64 = 0
pub static OVERRUNS: i64 = 0
pub static TRACED:   usize = 0
pub static TRACE:    [i64; 256]
pub static SOURCES:  i64 = 0

static CASE: i32 = 0
static EXIT: i32 = 0

pub eval ALIVE: u64 = 0xA11CE
pub eval MOVED: u64 = 0x30BED
pub eval DEAD:  u64 = 0xDEAD

/// Records one check. A failing check prints its name and fixes the exit
/// code at its own ordinal, the first failure winning.
pub fn expect(ok: bool, const name: string) {
    CASE += 1
    if !ok {
        io::println(f"FAIL check {CASE}: {name}")
        if EXIT == 0 {
            EXIT = CASE
        }
    }
}

/// The exit code: 0 when every check passed.
pub fn finish() -> i32 {
    return EXIT
}

/// Zeroes every counter and the trace.
pub fn reset() {
    LIVE = 0
    CTORS = 0
    MOVES = 0
    DTORS = 0
    ERRS = 0
    PULLS = 0
    BACKS = 0
    OVERRUNS = 0
    TRACED = 0
    SOURCES = 0
}

/// Every object made since reset() is destroyed exactly once, none was
/// touched in a bad state, and no source is left.
pub fn expect_balanced(const name: string) {
    expect(LIVE == 0 && ERRS == 0, f"{name}: {LIVE} live, {ERRS} bad touches")
    var made = CTORS + MOVES
    expect(DTORS == made, f"{name}: destroyed {DTORS} of {made}")
    expect(SOURCES == 0, f"{name}: {SOURCES} sources left")
}

/// expect_balanced, and no source was asked after its end.
pub fn expect_clean(const name: string) {
    expect_balanced(name)
    expect(OVERRUNS == 0, f"{name}: {OVERRUNS} calls after the end")
}

/// The source counters are exactly `front` and `back`.
pub fn expect_pulls(front: i64, back: i64, const name: string) {
    expect(PULLS == front && BACKS == back, f"{name}: pulled {PULLS} / {BACKS}, expected {front} / {back}")
}

fn trace(v: i64) {
    if TRACED < 256 {
        TRACE[TRACED] = v
    }

    TRACED += 1
}

/// The trace is exactly `want`.
pub fn expect_trace(const want: [i64], const name: string) {
    var same = TRACED == want.size()
    for var i: usize = 0; same && i < TRACED; ++i {
        same = TRACE[i] == want[i]
    }

    expect(same, f"{name}: trace differs ({TRACED} entries)")
}

pub interface Elem {
    static fn make(k: i64) -> Self
    fn key(const self) -> i64
}

extend i64 impl Elem {
    static fn make(k: i64) -> i64 = k
    fn key(const self) -> i64 = self
}

extend string impl Elem {
    static fn make(k: i64) -> string = f"e{k}"
    fn key(const self) -> i64 {
        var v: i64 = 0
        for var i: usize = 1; i < self.size(); ++i {
            v = v * 10 + ((self.bytes()[i] - ('0' as u8)) as i64)
        }

        return v
    }
}

pub class Counted {
    priv var state: u64
    priv var id:    i64

    pub fn Counted(self, id: i64) {
        self.state = ALIVE
        self.id    = id
        LIVE += 1
        CTORS += 1
    }

    @move pub fn Counted(self, other: Self) {
        if other.state != ALIVE {
            ERRS += 1
        }

        self.state  = ALIVE
        self.id     = other.id
        other.state = MOVED
        LIVE += 1
        MOVES += 1
    }

    pub fn op finally(self) {
        if self.state != ALIVE && self.state != MOVED {
            ERRS += 1
        }

        self.state = DEAD
        LIVE -= 1
        DTORS += 1
    }

    pub fn get(const self) -> i64 {
        if self.state != ALIVE {
            ERRS += 1
        }

        return self.id
    }
}

extend Counted impl Elem {
    static fn make(k: i64) -> Counted = Counted(k)
    fn key(const self) -> i64 = self.get()
}

/// Items `make(0) ... make(n - 1)`, from the front only.
pub class <E impl Elem> Fwd {
    var at:    i64
    var end:   i64
    var ended: bool

    pub fn Fwd(self, n: i64) {
        self.at    = 0
        self.end   = n
        self.ended = false
        SOURCES += 1
    }

    @move pub fn Fwd(self, other: Self) {
        self.at     = other.at
        self.end    = other.end
        self.ended  = other.ended
        other.ended = true
        other.at    = other.end
        SOURCES += 1
    }

    pub fn op finally(self) {
        SOURCES -= 1
    }
}

extend <E impl Elem> Fwd<E> impl Iterator {
    type Item = E
    fn next(self) -> E? {
        PULLS += 1
        if self.ended {
            OVERRUNS += 1
        }

        if self.at == self.end {
            self.ended = true
            return null
        }

        trace(self.at)
        self.at += 1
        return E::make(self.at - 1)
    }
}

/// Items `make(0) ... make(n - 1)`, from both ends, with an exact length.
pub class <E impl Elem> Both {
    var lo:    i64
    var hi:    i64
    var ended: bool

    pub fn Both(self, n: i64) {
        self.lo    = 0
        self.hi    = n
        self.ended = false
        SOURCES += 1
    }

    /// The items `make(lo) ... make(hi - 1)`.
    pub fn Both(self, lo: i64, hi: i64) {
        self.lo    = lo
        self.hi    = hi
        self.ended = false
        SOURCES += 1
    }

    @move pub fn Both(self, other: Self) {
        self.lo     = other.lo
        self.hi     = other.hi
        self.ended  = other.ended
        other.ended = true
        other.lo    = other.hi
        SOURCES += 1
    }

    pub fn op finally(self) {
        SOURCES -= 1
    }
}

extend <E impl Elem> Both<E> impl Iterator {
    type Item = E
    fn next(self) -> E? {
        PULLS += 1
        if self.ended {
            OVERRUNS += 1
        }

        if self.lo == self.hi {
            self.ended = true
            return null
        }

        trace(self.lo)
        self.lo += 1
        return E::make(self.lo - 1)
    }
}

extend <E impl Elem> Both<E> impl DoubleEnded {
    fn next_back(self) -> E? {
        BACKS += 1
        if self.ended {
            OVERRUNS += 1
        }

        if self.lo == self.hi {
            self.ended = true
            return null
        }

        self.hi -= 1
        trace(1000 + self.hi)
        return E::make(self.hi)
    }
}

extend <E impl Elem> Both<E> impl ExactSize {
    fn remaining(const self) -> usize = (self.hi - self.lo) as usize
}

/// The keys of a vector of items.
pub fn <E impl Elem> keys_are(const v: [E], const want: [i64]) -> bool {
    if v.size() != want.size() {
        return false
    }

    for var i: usize = 0; i < v.size(); ++i {
        if v[i].key() != want[i] {
            return false
        }
    }

    return true
}

/// The keys of a vector of integers.
pub fn ints_are(const v: [i64], const want: [i64]) -> bool = keys_are<i64>(v, want)

/// Pulls a chain dry with `next` and returns the keys in the order pulled.
pub fn <I impl Iterator> drain_keys(it: I) -> [i64] requires I::Item impl Elem {
    var got: [i64]
    var chain = move(it)
    loop {
        var x? = chain.next()
        if !x? {
            return move(got)
        }

        got.push(unwrap!(x).key())
    }
}

/// Callbacks. Each counts its calls in CALLS.
pub static CALLS: i64 = 0

pub fn <E impl Elem> same(x: E) -> E {
    CALLS += 1
    return x
}

pub fn <E impl Elem> key_of(x: E) -> i64 {
    CALLS += 1
    return x.key()
}

pub fn <E impl Elem> key_plus_100(x: E) -> i64 {
    CALLS += 1
    return x.key() + 100
}

pub fn <E impl Elem> is_even(x: *const E) -> bool {
    CALLS += 1
    return (x->key() & 1) == 0
}

pub fn <E impl Elem> is_odd(x: *const E) -> bool {
    CALLS += 1
    return (x->key() & 1) == 1
}

pub fn <E impl Elem> below_3(x: *const E) -> bool {
    CALLS += 1
    return x->key() < 3
}

pub fn <E impl Elem> below_5(x: *const E) -> bool {
    CALLS += 1
    return x->key() < 5
}

/// The item when its key is odd, null otherwise.
pub fn <E impl Elem> odd_only(x: E) -> E? {
    CALLS += 1
    if (x.key() & 1) == 1 {
        return move(x)
    }

    return null
}

/// The key of an item when it is a multiple of three, null otherwise.
pub fn <E impl Elem> third_key(x: E) -> i64? {
    CALLS += 1
    var k = x.key()
    if k % 3 == 0 {
        return k
    }

    return null
}

/// The key of the item, or -1 for null.
pub fn <E impl Elem> kor(x: E?) -> i64 {
    if x? {
        return unwrap!(x).key()
    }

    return -1
}

/// `index * 1000 + key` of an enumerated item.
pub fn <E impl Elem> indexed(p: (usize, E)) -> i64 {
    CALLS += 1
    return (p.0 as i64) * 1000 + p.1.key()
}

/// `left key * 1000 + right key` of a zipped pair.
pub fn <E impl Elem, F impl Elem> paired(p: (E, F)) -> i64 {
    CALLS += 1
    return p.0.key() * 1000 + p.1.key()
}

/// A source of `make(0) ... make(key - 1)` for the item's key.
pub fn <E impl Elem, F impl Elem> fwd_of(x: E) -> Fwd<F> {
    CALLS += 1
    return Fwd<F>(x.key())
}

/// A source of `make(0) ... make(key - 1)`, both-ended, for the item's key.
pub fn <E impl Elem, F impl Elem> both_of(x: E) -> Both<F> {
    CALLS += 1
    return Both<F>(x.key())
}

/// Sum of the keys seen by `record`.
pub static SUM: i64 = 0

pub fn <E impl Elem> record(x: E) {
    CALLS += 1
    SUM += x.key()
}

pub fn <E impl Elem> fold_key(acc: i64, x: E) -> i64 {
    CALLS += 1
    return acc * 10 + x.key()
}

/// The item with the larger key; the left one when they are equal.
pub fn <E impl Elem> keep_larger(a: E, b: E) -> E {
    CALLS += 1
    return if b.key() > a.key() => move(b) else => move(a)
}

pub fn <E impl Elem> is_two(x: *const E) -> bool {
    CALLS += 1
    return x->key() == 2
}

pub fn <E impl Elem> any_key(x: *const E) -> bool {
    CALLS += 1
    return x->key() >= 0
}

/// A move-only item ordered by `rank` alone: items of equal rank are told
/// apart by `tag`. It counts like Counted.
pub class Ranked {
    priv var state: u64
    pub var rank:   i64
    pub var tag:    i64

    pub fn Ranked(self, rank: i64, tag: i64) {
        self.state = ALIVE
        self.rank  = rank
        self.tag   = tag
        LIVE += 1
        CTORS += 1
    }

    @move pub fn Ranked(self, other: Self) {
        if other.state != ALIVE {
            ERRS += 1
        }

        self.state  = ALIVE
        self.rank   = other.rank
        self.tag    = other.tag
        other.state = MOVED
        LIVE += 1
        MOVES += 1
    }

    pub fn op finally(self) {
        if self.state != ALIVE && self.state != MOVED {
            ERRS += 1
        }

        self.state = DEAD
        LIVE -= 1
        DTORS += 1
    }

    pub fn op == (const self, const o: Ranked) -> bool = self.rank == o.rank

    pub fn op <=> (const self, const o: Ranked) -> Ordering {
        if self.state != ALIVE || o.state != ALIVE {
            ERRS += 1
        }

        return if self.rank < o.rank => Ordering::Less else => (if self.rank > o.rank => Ordering::Greater else => Ordering::Equal)
    }
}

/// `rank * 100 + tag`, one number that names an item of a vector of Ranked.
pub fn ranked_are(const v: [Ranked], const want: [i64]) -> bool {
    if v.size() != want.size() {
        return false
    }

    for var i: usize = 0; i < v.size(); ++i {
        if v[i].rank * 100 + v[i].tag != want[i] {
            return false
        }
    }

    return true
}
