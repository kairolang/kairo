// Pairs of adapters composed in both orders over the same items: the order
// decides the result, and each order gives the one its reading says.

import std::iter::*
import std::io

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

var failed: i32 = 0

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

fn upto(n: i64) -> yield i64 {
    for var i: i64 = 0; i < n; i += 1 {
        yield i
    }
}

fn add_ten(x: i64) -> i64 = x + 10
fn even(x: *const i64) -> bool = (*x & 1) == 0
fn below_four(x: *const i64) -> bool = *x < 4
fn below_thirteen(x: *const i64) -> bool = *x < 13
fn index_plus(e: (usize, i64)) -> i64 = (e.0 as i64) * 100 + e.1
fn pair_sum(e: (i64, i64)) -> i64 = e.0 * 100 + e.1
fn span_to(x: i64) -> Span = Span(0, x)
fn odd_only(x: i64) -> i64? {
    if (x & 1) == 1 {
        return x
    }

    return null
}

fn main() -> i32 {
    expect("map filter", iter(Span(1, 8)).map<i64>(add_ten).filter(even).collect<[i64]>(), [12, 14, 16])
    expect("filter map", iter(Span(1, 8)).filter(even).map<i64>(add_ten).collect<[i64]>(), [12, 14, 16])
    expect("map take_while", iter(Span(0, 8)).map<i64>(add_ten).take_while(below_thirteen).collect<[i64]>(), [10, 11, 12])
    expect("take_while map", iter(Span(0, 8)).take_while(below_four).map<i64>(add_ten).collect<[i64]>(), [10, 11, 12, 13])
    expect("filter take", iter(Span(0, 9)).filter(even).take(3).collect<[i64]>(), [0, 2, 4])
    expect("take filter", iter(Span(0, 9)).take(3).filter(even).collect<[i64]>(), [0, 2])
    expect("filter skip", iter(Span(0, 9)).filter(even).skip(2).collect<[i64]>(), [4, 6, 8])
    expect("skip filter", iter(Span(0, 9)).skip(2).filter(even).collect<[i64]>(), [2, 4, 6, 8])
    expect("take skip", iter(Span(0, 9)).take(5).skip(2).collect<[i64]>(), [2, 3, 4])
    expect("skip take", iter(Span(0, 9)).skip(2).take(5).collect<[i64]>(), [2, 3, 4, 5, 6])
    expect("step_by take", iter(Span(0, 9)).step_by(3).take(2).collect<[i64]>(), [0, 3])
    expect("take step_by", iter(Span(0, 9)).take(5).step_by(3).collect<[i64]>(), [0, 3])
    expect("step_by skip", iter(Span(0, 9)).step_by(2).skip(1).collect<[i64]>(), [2, 4, 6, 8])
    expect("skip step_by", iter(Span(0, 9)).skip(1).step_by(2).collect<[i64]>(), [1, 3, 5, 7])
    expect("take_while skip_while", iter(Span(0, 9)).take_while(below_four).skip_while(even).collect<[i64]>(), [1, 2, 3])
    expect("skip_while take_while", iter(Span(0, 9)).skip_while(even).take_while(below_four).collect<[i64]>(), [1, 2, 3])
    expect("skip_while filter", iter(Span(0, 9)).skip_while(below_four).filter(even).collect<[i64]>(), [4, 6, 8])
    expect("filter skip_while", iter(Span(0, 9)).filter(even).skip_while(below_four).collect<[i64]>(), [4, 6, 8])
    expect("chain take", iter(Span(0, 2)).chain(Span(5, 9)).take(3).collect<[i64]>(), [0, 1, 5])
    expect("take chain", iter(Span(0, 9)).take(3).chain(Span(5, 7)).collect<[i64]>(), [0, 1, 2, 5, 6])
    expect("chain filter", iter(Span(0, 3)).chain(Span(5, 8)).filter(even).collect<[i64]>(), [0, 2, 6])
    expect("filter chain", iter(Span(0, 3)).filter(even).chain(Span(5, 8)).collect<[i64]>(), [0, 2, 5, 6, 7])
    expect("chain skip", iter(Span(0, 2)).chain(Span(5, 8)).skip(3).collect<[i64]>(), [6, 7])
    expect("skip chain", iter(Span(0, 2)).skip(3).chain(Span(5, 8)).collect<[i64]>(), [5, 6, 7])
    expect("enumerate filter", iter(Span(5, 9)).filter(even).enumerate().map<i64>(index_plus).collect<[i64]>(), [6, 108])
    expect("enumerate skip", iter(Span(5, 9)).enumerate().skip(2).map<i64>(index_plus).collect<[i64]>(), [207, 308])
    expect("skip enumerate", iter(Span(5, 9)).skip(2).enumerate().map<i64>(index_plus).collect<[i64]>(), [7, 108])
    expect("enumerate take", iter(Span(5, 9)).enumerate().take(2).map<i64>(index_plus).collect<[i64]>(), [5, 106])
    expect("enumerate step_by", iter(Span(5, 9)).enumerate().step_by(3).map<i64>(index_plus).collect<[i64]>(), [5, 308])
    expect("step_by enumerate", iter(Span(5, 9)).step_by(3).enumerate().map<i64>(index_plus).collect<[i64]>(), [5, 108])
    expect("zip take", iter(Span(1, 9)).zip(upto(9)).take(2).map<i64>(pair_sum).collect<[i64]>(), [100, 201])
    expect("take zip", iter(Span(1, 9)).take(2).zip(upto(9)).map<i64>(pair_sum).collect<[i64]>(), [100, 201])
    expect("zip filter", iter(Span(1, 6)).filter(even).zip(upto(9)).map<i64>(pair_sum).collect<[i64]>(), [200, 401])
    expect("flat_map take", iter(Span(0, 5)).flat_map<Span>(span_to).take(4).collect<[i64]>(), [0, 0, 1, 0])
    expect("take flat_map", iter(Span(0, 5)).take(3).flat_map<Span>(span_to).collect<[i64]>(), [0, 0, 1])
    expect("flat_map filter", iter(Span(0, 4)).flat_map<Span>(span_to).filter(even).collect<[i64]>(), [0, 0, 0, 2])
    expect("filter flat_map", iter(Span(0, 4)).filter(even).flat_map<Span>(span_to).collect<[i64]>(), [0, 1])
    expect("filter_map map", iter(Span(0, 6)).filter_map<i64>(odd_only).map<i64>(add_ten).collect<[i64]>(), [11, 13, 15])
    expect("map filter_map", iter(Span(0, 6)).map<i64>(add_ten).filter_map<i64>(odd_only).collect<[i64]>(), [11, 13, 15])
    expect("peekable take", iter(Span(0, 6)).peekable().take(2).collect<[i64]>(), [0, 1])
    expect("take peekable", iter(Span(0, 6)).take(2).peekable().collect<[i64]>(), [0, 1])
    expect("peekable filter", iter(upto(6)).peekable().filter(even).collect<[i64]>(), [0, 2, 4])
    expect("filter peekable", iter(upto(6)).filter(even).peekable().collect<[i64]>(), [0, 2, 4])
    expect(
        "five deep",
        iter(upto(40)).skip(2).step_by(2).map<i64>(add_ten).filter(even).take(3).collect<[i64]>(),
        [12, 14, 16],
    )

    return failed
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo -O2 %s -o %t.O2.exe --cache-dir %t.d
// RUN: %t.O2.exe
