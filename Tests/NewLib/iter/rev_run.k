// The adapters that read from the back: `rev` applies to a chain whose
// every link is DoubleEnded (a source that is, then `map`, `filter`,
// `chain`, `rev`), and any adapter can follow it.

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
fn even(x: *const i64) -> bool = (*x & 1) == 0

fn reversed() {
    expect("rev 0", iter(Span(0, 0)).rev().collect<[i64]>(), none())
    expect("rev 1", iter(Span(4, 5)).rev().collect<[i64]>(), [4])
    expect("rev n", iter(Span(0, 4)).rev().collect<[i64]>(), [3, 2, 1, 0])
    expect("rev rev", iter(Span(0, 4)).rev().rev().collect<[i64]>(), [0, 1, 2, 3])

    expect("map rev 0", iter(Span(0, 0)).map<i64>(twice).rev().collect<[i64]>(), none())
    expect("map rev n", iter(Span(0, 4)).map<i64>(twice).rev().collect<[i64]>(), [6, 4, 2, 0])
    expect("rev map n", iter(Span(0, 4)).rev().map<i64>(twice).collect<[i64]>(), [6, 4, 2, 0])

    expect("filter rev 0", iter(Span(0, 0)).filter(even).rev().collect<[i64]>(), none())
    expect("filter rev 1", iter(Span(1, 2)).filter(even).rev().collect<[i64]>(), none())
    expect("filter rev n", iter(Span(0, 7)).filter(even).rev().collect<[i64]>(), [6, 4, 2, 0])
    expect("rev filter n", iter(Span(0, 7)).rev().filter(even).collect<[i64]>(), [6, 4, 2, 0])

    expect("chain rev 0 0", iter(Span(0, 0)).chain(Span(0, 0)).rev().collect<[i64]>(), none())
    expect("chain rev n 0", iter(Span(0, 2)).chain(Span(0, 0)).rev().collect<[i64]>(), [1, 0])
    expect("chain rev 0 n", iter(Span(0, 0)).chain(Span(7, 9)).rev().collect<[i64]>(), [8, 7])
    expect("chain rev n n", iter(Span(0, 2)).chain(Span(7, 9)).rev().collect<[i64]>(), [8, 7, 1, 0])

    expect(
        "map filter rev",
        iter(Span(0, 5)).map<i64>(twice).filter(even).rev().collect<[i64]>(),
        [8, 6, 4, 2, 0],
    )

    expect("rev take", iter(Span(0, 9)).rev().take(2).collect<[i64]>(), [8, 7])
    expect("rev skip", iter(Span(0, 4)).rev().skip(3).collect<[i64]>(), [0])
    expect("rev step_by", iter(Span(0, 7)).rev().step_by(3).collect<[i64]>(), [6, 3, 0])
}

fn main() -> i32 {
    reversed()
    return failed
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo_new -O2 %s -o %t.O2.exe --cache-dir %t.d
// RUN: %t.O2.exe
