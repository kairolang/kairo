// The adapters that know their length: `remaining` on a chain whose every
// link is ExactSize (`map`, `enumerate`, `zip`, `take`, `skip`, `rev`). A
// skip longer than what is left reports zero.

import std::iter::*
import std::io

/// Counts from `lo` up to `hi` (exclusive) at the front, down at the back.
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

extend Span impl DoubleEnded {
    fn next_back(self) -> i64? {
        if self.lo == self.hi {
            return null
        }

        self.hi -= 1
        return self.hi
    }
}

extend Span impl ExactSize {
    fn remaining(const self) -> usize = (self.hi - self.lo) as usize
}

var failed: i32 = 0

/// Counts a chain whose items are not `want` and prints its label.
fn expect(const label: string, const got: [i64], const want: [i64]) {
    var same = got.size() == want.size()
    for var i: usize = 0; same && i < got.size(); i += 1 {
        same = got[i] == want[i]
    }

    if !same {
        failed += 1
        var s: string
        for x in got {
            s += f" {x}"
        }

        io::println(f"FAILED {label}: got{s}")
    }
}

fn hold(const label: string, cond: bool) {
    if !cond {
        failed += 1
        io::println(f"FAILED {label}")
    }
}

fn none() -> [i64] {
    var v: [i64]
    return v
}

fn twice(x: i64) -> i64 = x * 2

/// `remaining` through a bound, which is how a generic consumer reads it.
fn <I impl ExactSize> left(const it: I) -> usize = it.remaining()

fn lengths() {
    hold("iter remaining", left(iter(Span(0, 5))) == 5)
    hold("iter remaining 0", left(iter(Span(3, 3))) == 0)
    hold("map remaining", left(iter(Span(0, 5)).map<i64>(twice)) == 5)
    hold("enumerate remaining", left(iter(Span(0, 5)).enumerate()) == 5)
    hold("rev remaining", left(iter(Span(0, 5)).rev()) == 5)
    hold("zip remaining short b", left(iter(Span(0, 5)).zip(Span(0, 2))) == 2)
    hold("zip remaining short a", left(iter(Span(0, 1)).zip(Span(0, 9))) == 1)
    hold("take remaining", left(iter(Span(0, 5)).take(3)) == 3)
    hold("take remaining past the end", left(iter(Span(0, 5)).take(9)) == 5)
    hold("take 0 remaining", left(iter(Span(0, 5)).take(0)) == 0)
    hold("skip remaining", left(iter(Span(0, 5)).skip(2)) == 3)
    hold("skip all remaining", left(iter(Span(0, 5)).skip(5)) == 0)
    hold("skip past the end remaining", left(iter(Span(0, 5)).skip(9)) == 0)
    hold("skip of none remaining", left(iter(Span(0, 0)).skip(usize::MAX)) == 0)
    hold(
        "nested remaining",
        left(iter(Span(0, 9)).rev().skip(2).take(5).map<i64>(twice).enumerate()) == 5,
    )

    var c = iter(Span(0, 5)).skip(2)
    hold("skip counts down 0", left(c) == 3)
    hold("skip first", (c.next() ?? -1) == 2)
    hold("skip counts down 1", left(c) == 2)
    var t = iter(Span(0, 5)).take(2)
    hold("take first", (t.next() ?? -1) == 0 && left(t) == 1)
    hold("take second", (t.next() ?? -1) == 1 && left(t) == 0)
    hold("take end", !t.next()? && left(t) == 0)
    var r = iter(Span(0, 3)).map<i64>(twice).rev()
    hold("rev map first", (r.next() ?? -1) == 4 && left(r) == 2)
}

fn main() -> i32 {
    lengths()
    return failed
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
