// The iterator interfaces: a generator is an Iterator through `Yield`'s
// `next`, for a COPY item and a move-only one, with no, one and many items;
// a user type implements Iterator, DoubleEnded and ExactSize. FromIterator
// is in iter_from_iterator.k.

import std::io

fn count_to(n: i32) -> yield i32 {
    for var i = 0; i < n; i++ {
        yield i * i
    }
}

fn words(n: i32) -> yield string {
    if n > 0 {
        yield "one"
    }

    if n > 1 {
        yield "two"
    }

    if n > 2 {
        yield "three"
    }
}

// A generator taken by its own type: as a `G impl Iterator` bound it does
// not conform yet (iter_yield_bound.k).
fn drain_i32(it: Yield<i32>) -> i32 {
    var t = 0
    while true {
        var x = it.next()
        if !x? {
            break
        }

        t += x ?? 0
    }

    return t
}

/// Counts down from `hi` to `lo` (exclusive) at the front, up at the back.
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

fn <I impl Iterator> drain_i64(it: I) -> i64 requires __builtin_is_same<I::Item, i64>() {
    var t: i64 = 0
    while true {
        var x = it.next()
        if !x? {
            break
        }

        t += unwrap!(x)
    }

    return t
}

fn main() -> i32 {
    io::println(f"{drain_i32(count_to(0))} {drain_i32(count_to(1))} {drain_i32(count_to(5))}")

    for var n = 0; n < 4; n++ {
        var g     = words(n)
        var total: usize = 0
        var k     = 0
        while true {
            var w = g.next()
            if !w? {
                break
            }

            total += unwrap!(w).size()
            k     += 1
        }

        io::println(f"words({n}): {k} items, {total} bytes")
    }

    io::println(f"span sum {drain_i64(Span(2, 6))}")
    var s = Span(0, 5)
    var f = s.next() ?? -1
    var b = s.next_back() ?? -1
    io::println(f"front {f} back {b} left {s.remaining()}")
    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK:      0 0 30
// CHECK-NEXT: words(0): 0 items, 0 bytes
// CHECK-NEXT: words(1): 1 items, 3 bytes
// CHECK-NEXT: words(2): 2 items, 6 bytes
// CHECK-NEXT: words(3): 3 items, 11 bytes
// CHECK-NEXT: span sum 14
// CHECK-NEXT: front 0 back 4 left 3
