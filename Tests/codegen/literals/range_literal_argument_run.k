// A range literal whose bounds are untyped integer literals takes its element
// type from the range it is passed to, in every argument position, as one
// integer literal takes its parameter's type: `1..3` is a `Range<usize>` at
// a `Range<usize>` parameter and a `Range<u8>` at a `Range<u8>` one. The open
// forms build the record of their shape (`a..` a RangeFrom, `..b` and `..=b`
// a RangeTo), which also selects among overloads. A bound with a type of its
// own keeps it, and the other bound follows.

fn span(r: Range<usize>) -> usize {
    var n = r.end - r.begin
    if r.inclusive {
        n += 1
    }

    return n
}

fn start(r: RangeFrom<usize>) -> usize {
    return r.begin
}

fn stop(r: RangeTo<usize>) -> usize {
    if r.inclusive {
        return r.end + 1
    }

    return r.end
}

fn narrow(r: Range<u8>) -> u8 {
    return r.end - r.begin
}

fn which(r: Range<usize>) -> i32 = 1
fn which(r: RangeFrom<usize>) -> i32 = 2
fn which(r: RangeTo<usize>) -> i32 = 3

fn <T> scaled(unit: T, r: Range<T>) -> T {
    return r.end
}

class Window {
    pub var len: usize

    pub fn Window(self, r: Range<usize>) {
        self.len = r.end - r.begin
    }

    pub fn cut(const self, r: Range<usize>) -> usize {
        return self.len - (r.end - r.begin)
    }

    pub static fn of(r: Range<usize>) -> usize {
        return r.end
    }
}

class <T> Seq {
    pub var n: usize

    pub fn Seq(self) {
        self.n = 10
    }

    pub fn drain(self, r: Range<usize>) -> usize {
        self.n -= r.end - r.begin
        return self.n
    }
}

class <T> Holder {
    pub var v: T

    pub fn Holder(self, v: T) {
        self.v = v
    }

    pub fn cut(const self, r: Range<usize>) -> usize {
        return r.end - r.begin
    }

    pub fn whole(const self) -> usize {
        return self.cut(0..2)
    }
}

// A receiver whose arguments are the body's own parameters.
fn <T> held(h: Holder<T>) -> usize {
    return h.cut(2..5)
}

// A callee only the instance picks: the range is what it is with nothing
// asking, a `Range<i32>`.
fn width(a: i32, r: Range<i32>) -> i32 {
    return r.end - r.begin + a
}

fn <...T> forward(...args: T) -> i32 {
    return width(args..., 0..3)
}

fn main() -> i32 {
    if span(1..3) != 2 { return 1 }                 // free function
    if span(1..=3) != 3 { return 2 }                // inclusive
    if span((2..9)) != 7 { return 3 }               // through parentheses
    if span(1..1 + 4) != 4 { return 4 }             // literal arithmetic
    if start(4..) != 4 { return 5 }
    if stop(..5) != 5 { return 6 }
    if stop(..=5) != 6 { return 7 }
    if narrow(250..255) != 5 { return 8 }
    if which(0..2) != 1 || which(2..) != 2 || which(..2) != 3 { return 9 }

    var w = Window(2..6)                            // constructor
    if w.len != 4 { return 10 }
    if w.cut(0..1) != 3 { return 11 }               // method
    if Window::of(0..7) != 7 { return 12 }          // static

    var s = Seq<i32>()
    if s.drain(0..2) != 8 { return 13 }             // a generic class's method

    var unit: usize = 1
    if scaled(unit, 0..9) != 9 { return 14 }        // T deduced by `unit`

    var lo: usize = 3
    if span(lo..8) != 5 { return 15 }               // the typed bound decides
    if span(0..lo) != 3 { return 16 }

    var r: Range<usize> = 1..4                      // a declared type asks too
    if span(r) != 3 { return 17 }
    var f: RangeFrom<usize> = 6..
    if start(f) != 6 { return 18 }

    var h = Holder<i32>(1)
    if h.whole() != 2 || held(h) != 3 { return 19 }
    if forward(1) != 4 { return 20 }

    var plain = 1..3                                // nothing asks: Range<i32>
    var d: i32 = plain.end - plain.begin
    return d - 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
