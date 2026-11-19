// A conformance an adapter has only when its source does (`extend <I impl
// DoubleEnded> Filter<I> impl DoubleEnded`) gets its witness wherever it is
// used, over a nested instance too: `rev` of `map.filter.chain` needs the
// witnesses of `Filter<Map<Span, i64>>` and of the chain over it, and
// `remaining` called on a wrapped adapter needs `Map<Span, i64>`'s.

import std::iter::*

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

fn twice(x: i64) -> i64 = x * 2
fn even(x: *const i64) -> bool = (*x & 1) == 0

fn main() -> i32 {
    var got = iter(Span(0, 5)).map<i64>(twice).filter(even).chain(Span(20, 22)).rev().collect<[i64]>()
    var want: [i64] = [21, 20, 8, 6, 4, 2, 0]
    if got.size() != want.size() {
        return 1
    }

    for var i: usize = 0; i < got.size(); i += 1 {
        if got[i] != want[i] {
            return 2
        }
    }

    return iter(Span(0, 5)).map<i64>(twice).remaining() as i32 - 5
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
