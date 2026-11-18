// Each adapter alone, over no item, one item and several, from a generator
// and from a hand-written iterator. `expect` prints the label of a chain
// whose items are not the ones listed; the exit status counts them.

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

fn upto(n: i64) -> yield i64 {
    for var i: i64 = 0; i < n; i += 1 {
        yield i
    }
}

static failed: i32 = 0

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

fn none() -> [i64] {
    var v: [i64]
    return v
}

fn twice(x: i64) -> i64 = x * 2
fn even(x: *const i64) -> bool = (*x & 1) == 0
fn below_three(x: *const i64) -> bool = *x < 3
fn span_to(x: i64) -> Span = Span(0, x)
fn gen_to(x: i64) -> Yield<i64> = upto(x)
fn half_of_even(x: i64) -> i64? {
    if (x & 1) == 0 {
        return x / 2
    }

    return null
}

fn over_span() {
    expect("map 0", iter(Span(0, 0)).map<i64>(twice).collect<[i64]>(), none())
    expect("map 1", iter(Span(3, 4)).map<i64>(twice).collect<[i64]>(), [6])
    expect("map n", iter(Span(0, 4)).map<i64>(twice).collect<[i64]>(), [0, 2, 4, 6])

    expect("filter 0", iter(Span(0, 0)).filter(even).collect<[i64]>(), none())
    expect("filter 1 kept", iter(Span(2, 3)).filter(even).collect<[i64]>(), [2])
    expect("filter 1 dropped", iter(Span(1, 2)).filter(even).collect<[i64]>(), none())
    expect("filter n", iter(Span(0, 7)).filter(even).collect<[i64]>(), [0, 2, 4, 6])

    expect("filter_map 0", iter(Span(0, 0)).filter_map<i64>(half_of_even).collect<[i64]>(), none())
    expect("filter_map 1", iter(Span(4, 5)).filter_map<i64>(half_of_even).collect<[i64]>(), [2])
    expect("filter_map n", iter(Span(0, 7)).filter_map<i64>(half_of_even).collect<[i64]>(), [0, 1, 2, 3])

    expect("flat_map 0", iter(Span(0, 0)).flat_map<Span>(span_to).collect<[i64]>(), none())
    expect("flat_map 1 empty", iter(Span(0, 1)).flat_map<Span>(span_to).collect<[i64]>(), none())
    expect("flat_map 1", iter(Span(2, 3)).flat_map<Span>(span_to).collect<[i64]>(), [0, 1])
    expect("flat_map n", iter(Span(0, 4)).flat_map<Span>(span_to).collect<[i64]>(), [0, 0, 1, 0, 1, 2])

    expect("take 0 of 0", iter(Span(0, 0)).take(3).collect<[i64]>(), none())
    expect("take 0 of n", iter(Span(0, 5)).take(0).collect<[i64]>(), none())
    expect("take 1", iter(Span(0, 5)).take(1).collect<[i64]>(), [0])
    expect("take n", iter(Span(0, 5)).take(3).collect<[i64]>(), [0, 1, 2])
    expect("take past the end", iter(Span(0, 2)).take(9).collect<[i64]>(), [0, 1])

    expect("skip 0 of 0", iter(Span(0, 0)).skip(2).collect<[i64]>(), none())
    expect("skip none", iter(Span(0, 3)).skip(0).collect<[i64]>(), [0, 1, 2])
    expect("skip n", iter(Span(0, 5)).skip(3).collect<[i64]>(), [3, 4])
    expect("skip all", iter(Span(0, 3)).skip(3).collect<[i64]>(), none())
    expect("skip past the end", iter(Span(0, 3)).skip(9).collect<[i64]>(), none())

    expect("take_while 0", iter(Span(0, 0)).take_while(below_three).collect<[i64]>(), none())
    expect("take_while 1", iter(Span(2, 3)).take_while(below_three).collect<[i64]>(), [2])
    expect("take_while none", iter(Span(5, 9)).take_while(below_three).collect<[i64]>(), none())
    expect("take_while n", iter(Span(0, 9)).take_while(below_three).collect<[i64]>(), [0, 1, 2])
    expect("take_while all", iter(Span(0, 2)).take_while(below_three).collect<[i64]>(), [0, 1])

    expect("skip_while 0", iter(Span(0, 0)).skip_while(below_three).collect<[i64]>(), none())
    expect("skip_while 1", iter(Span(7, 8)).skip_while(below_three).collect<[i64]>(), [7])
    expect("skip_while n", iter(Span(0, 6)).skip_while(below_three).collect<[i64]>(), [3, 4, 5])
    expect("skip_while all", iter(Span(0, 3)).skip_while(below_three).collect<[i64]>(), none())

    expect("step_by 0", iter(Span(0, 0)).step_by(2).collect<[i64]>(), none())
    expect("step_by 1", iter(Span(4, 5)).step_by(2).collect<[i64]>(), [4])
    expect("step_by one", iter(Span(0, 4)).step_by(1).collect<[i64]>(), [0, 1, 2, 3])
    expect("step_by n", iter(Span(0, 7)).step_by(3).collect<[i64]>(), [0, 3, 6])
    expect("step_by short tail", iter(Span(0, 8)).step_by(3).collect<[i64]>(), [0, 3, 6])
    expect("step_by wide", iter(Span(0, 3)).step_by(9).collect<[i64]>(), [0])

    expect("chain 0 0", iter(Span(0, 0)).chain(Span(0, 0)).collect<[i64]>(), none())
    expect("chain 0 n", iter(Span(0, 0)).chain(Span(7, 9)).collect<[i64]>(), [7, 8])
    expect("chain n 0", iter(Span(0, 2)).chain(Span(0, 0)).collect<[i64]>(), [0, 1])
    expect("chain 1 1", iter(Span(1, 2)).chain(Span(5, 6)).collect<[i64]>(), [1, 5])
    expect("chain n n", iter(Span(0, 2)).chain(Span(7, 9)).collect<[i64]>(), [0, 1, 7, 8])

    expect("peekable 0", iter(Span(0, 0)).peekable().collect<[i64]>(), none())
    expect("peekable 1", iter(Span(6, 7)).peekable().collect<[i64]>(), [6])
    expect("peekable n", iter(Span(0, 3)).peekable().collect<[i64]>(), [0, 1, 2])
}

fn over_generator() {
    expect("gen map 0", iter(upto(0)).map<i64>(twice).collect<[i64]>(), none())
    expect("gen map 1", iter(upto(1)).map<i64>(twice).collect<[i64]>(), [0])
    expect("gen map n", iter(upto(4)).map<i64>(twice).collect<[i64]>(), [0, 2, 4, 6])
    expect("gen filter n", iter(upto(7)).filter(even).collect<[i64]>(), [0, 2, 4, 6])
    expect("gen filter_map n", iter(upto(7)).filter_map<i64>(half_of_even).collect<[i64]>(), [0, 1, 2, 3])
    expect("gen flat_map n", iter(upto(4)).flat_map<Yield<i64>>(gen_to).collect<[i64]>(), [0, 0, 1, 0, 1, 2])
    expect("gen take n", iter(upto(5)).take(3).collect<[i64]>(), [0, 1, 2])
    expect("gen take 0", iter(upto(5)).take(0).collect<[i64]>(), none())
    expect("gen skip n", iter(upto(5)).skip(3).collect<[i64]>(), [3, 4])
    expect("gen skip past the end", iter(upto(3)).skip(9).collect<[i64]>(), none())
    expect("gen take_while n", iter(upto(9)).take_while(below_three).collect<[i64]>(), [0, 1, 2])
    expect("gen skip_while n", iter(upto(6)).skip_while(below_three).collect<[i64]>(), [3, 4, 5])
    expect("gen step_by n", iter(upto(8)).step_by(3).collect<[i64]>(), [0, 3, 6])
    expect("gen chain n n", iter(upto(2)).chain(upto(3)).collect<[i64]>(), [0, 1, 0, 1, 2])
    expect("gen chain 0 n", iter(upto(0)).chain(upto(2)).collect<[i64]>(), [0, 1])
    expect("gen chain mixed", iter(upto(2)).chain(Span(7, 9)).collect<[i64]>(), [0, 1, 7, 8])
    expect("gen peekable n", iter(upto(3)).peekable().collect<[i64]>(), [0, 1, 2])
}

fn pairs() {
    var e0 = iter(Span(0, 0)).enumerate().collect<[(usize, i64)]>()
    var e1 = iter(Span(9, 10)).enumerate().collect<[(usize, i64)]>()
    var en = iter(upto(3)).map<i64>(twice).enumerate().collect<[(usize, i64)]>()
    if e0.size() != 0 || e1.size() != 1 || e1[0].0 != 0 || e1[0].1 != 9 {
        failed += 1
        io::println("FAILED enumerate 0 / 1")
    }

    if en.size() != 3 || en[2].0 != 2 || en[2].1 != 4 || en[1].0 != 1 || en[1].1 != 2 {
        failed += 1
        io::println("FAILED enumerate n")
    }

    var z0 = iter(Span(0, 0)).zip(Span(0, 4)).collect<[(i64, i64)]>()
    var z1 = iter(Span(5, 9)).zip(Span(0, 1)).collect<[(i64, i64)]>()
    var zn = iter(upto(3)).zip(Span(5, 99)).collect<[(i64, i64)]>()
    if z0.size() != 0 || z1.size() != 1 || z1[0].0 != 5 || z1[0].1 != 0 {
        failed += 1
        io::println("FAILED zip 0 / 1")
    }

    if zn.size() != 3 || zn[2].0 != 2 || zn[2].1 != 7 {
        failed += 1
        io::println("FAILED zip n")
    }
}

fn main() -> i32 {
    over_span()
    over_generator()
    pairs()
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
