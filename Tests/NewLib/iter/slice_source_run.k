// The slice source `iter_slice_`: the elements by pointer from either end,
// with their count. It gives what `iter(s.iter())` gives, and what that
// cannot: `rev`, a `take` that cuts the source, and a `collect` that sizes
// its vector once (the capacity is the length, where pushing would have
// grown past it).

import std::iter::*
import std::io

var failed: i32 = 0

fn hold(const label: string, cond: bool) {
    if !cond {
        failed += 1
        io::println(f"FAILED {label}")
    }
}

fn triple(x: i32) -> i32 = x * 3
fn is_even(x: *const i32) -> bool = (*x & 1) == 0
fn below_ten(x: *const i32) -> bool = *x < 10
fn deref(p: *const i32) -> i32 = *p
fn weigh(acc: i64, e: (usize, *const i32)) -> i64 = acc + (e.0 as i64) * (*e.1 as i64)
fn pair_product(e: (i32, i32)) -> i32 = e.0 * e.1
fn shout(p: *const string) -> string = f"{*p}!"
fn text_size(p: *const string) -> usize = p->size()
fn digits(acc: i64, x: i32) -> i64 = acc * 10 + (x as i64)

/// The wrapper has no `next_back`, so the back end is read through `rev`,
/// whose `rev` is the front again.
fn ends(const s: [const i32;]) {
    var c = iter_slice_(s)
    var a? = c.next()
    hold("front", a? && *unwrap!(a) == 1)
    var r = c.rev()
    var z? = r.next()
    var y? = r.next()
    hold("back", z? && y? && *unwrap!(z) == 5 && *unwrap!(y) == 4)
    var f = r.rev()
    var b? = f.next()
    var m? = f.next()
    var none? = f.next()
    hold("the two ends meet", b? && m? && !none? && *unwrap!(b) == 2 && *unwrap!(m) == 3)
}

fn sizes() {
    var none: [i32]
    var one: [i32] = [7]
    var many: [i32] = [1, 2, 3, 4, 5]
    var e: [const i32;] = none
    var o: [const i32;] = one
    var m: [const i32;] = many

    hold("empty count", iter_slice_(e).count() == 0)
    hold("empty sum", iter_slice_(e).copied().sum() == 0)
    hold("empty rev", iter_slice_(e).rev().count() == 0)
    hold("empty collect", iter_slice_(e).copied().collect<[i32]>().size() == 0)
    hold("empty take", iter_slice_(e).copied().take(3).count() == 0)
    var no_last? = iter_slice_(e).copied().last()
    hold("empty last", !no_last?)

    hold("one count", iter_slice_(o).count() == 1)
    hold("one sum", iter_slice_(o).copied().sum() == 7)
    hold("one rev", iter_slice_(o).copied().rev().fold<i64>(0, digits) == 7)
    hold("one collect", iter_slice_(o).copied().map<i32>(triple).collect<[i32]>()[0] == 21)

    hold("many forward", iter_slice_(m).copied().fold<i64>(0, digits) == 12345)
    hold("many backward", iter_slice_(m).copied().rev().fold<i64>(0, digits) == 54321)
    hold("rev of rev", iter_slice_(m).copied().rev().rev().fold<i64>(0, digits) == 12345)
    hold("pointers", iter_slice_(m).map<i32>(deref).fold<i64>(0, digits) == 12345)
    hold("pointers backward", iter_slice_(m).rev().map<i32>(deref).fold<i64>(0, digits) == 54321)
    hold("the generator agrees", iter(m.iter()).copied().fold<i64>(0, digits) == 12345)
    hold("map filter sum", iter_slice_(m).copied().map<i32>(triple).filter(is_even).sum() == 18)
    hold("filter backward", iter_slice_(m).copied().filter(is_even).rev().fold<i64>(0, digits) == 42)
    hold("map backward", iter_slice_(m).copied().map<i32>(triple).rev().fold<i64>(0, digits) == 15 * 10000 + 12 * 1000 + 9 * 100 + 6 * 10 + 3)
}

fn cuts(const m: [const i32;]) {
    hold("take", iter_slice_(m).copied().take(3).fold<i64>(0, digits) == 123)
    hold("take none", iter_slice_(m).copied().take(0).count() == 0)
    hold("take past the end", iter_slice_(m).copied().take(9).fold<i64>(0, digits) == 12345)
    hold("take of take", iter_slice_(m).copied().take(4).take(2).fold<i64>(0, digits) == 12)
    hold("take from the back", iter_slice_(m).copied().rev().take(2).fold<i64>(0, digits) == 54)
    hold("take under map", iter_slice_(m).copied().map<i32>(triple).take(2).fold<i64>(0, digits) == 36)
    hold("take after filter", iter_slice_(m).copied().filter(is_even).take(1).fold<i64>(0, digits) == 2)
    hold("enumerate take", iter_slice_(m).enumerate().take(3).fold<i64>(0, weigh) == 0 * 1 + 1 * 2 + 2 * 3)
    hold("skip", iter_slice_(m).copied().skip(2).fold<i64>(0, digits) == 345)
    hold("skip past the end", iter_slice_(m).copied().skip(7).count() == 0)
    hold("skip take", iter_slice_(m).copied().skip(1).take(2).fold<i64>(0, digits) == 23)
    hold("skip from the back", iter_slice_(m).copied().rev().skip(3).fold<i64>(0, digits) == 21)
    hold("step_by", iter_slice_(m).copied().step_by(2).fold<i64>(0, digits) == 135)
    hold("take_while", iter_slice_(m).copied().take_while(below_ten).count() == 5)
    hold("zip", iter_slice_(m).copied().zip(iter_slice_(m).copied().rev()).map<i32>(pair_product).sum() == 5 + 8 + 9 + 8 + 5)
    hold("zip take", iter_slice_(m).copied().zip(iter_slice_(m).copied()).take(2).map<i32>(pair_product).sum() == 1 + 4)
    hold("chain", iter_slice_(m).copied().take(2).chain(iter_slice_(m).copied().rev().take(2)).fold<i64>(0, digits) == 1254)
    var third? = iter_slice_(m).copied().nth(2)
    hold("nth", third? && unwrap!(third) == 3)
    var found? = iter_slice_(m).copied().rev().find(is_even)
    hold("find from the back", found? && unwrap!(found) == 4)
}

/// A vector collected from a chain whose length is exact has that length
/// as its capacity: it was allocated once, for exactly its items.
fn collects(const m: [const i32;]) {
    var a = iter_slice_(m).copied().map<i32>(triple).collect<[i32]>()
    hold("collect", a.size() == 5 && a.capacity() == 5 && a[0] == 3 && a[4] == 15)
    var b = iter_slice_(m).copied().rev().collect<[i32]>()
    hold("collect backward", b.size() == 5 && b.capacity() == 5 && b[0] == 5 && b[4] == 1)
    var c = iter_slice_(m).copied().take(3).collect<[i32]>()
    hold("collect take", c.size() == 3 && c.capacity() == 3 && c[2] == 3)
    var d = iter_slice_(m).copied().skip(4).collect<[i32]>()
    hold("collect skip", d.size() == 1 && d.capacity() == 1 && d[0] == 5)
    var e = iter_slice_(m).copied().step_by(2).collect<[i32]>()
    hold("collect step_by", e.size() == 3 && e.capacity() == 3 && e[2] == 5)
    var f = iter_slice_(m).copied().skip(1).step_by(3).collect<[i32]>()
    hold("collect skip step_by", f.size() == 2 && f.capacity() == 2 && f[0] == 2 && f[1] == 5)
    var g = iter_slice_(m).copied().zip(iter_slice_(m).copied().take(2)).map<i32>(pair_product).collect<[i32]>()
    hold("collect zip", g.size() == 2 && g.capacity() == 2 && g[1] == 4)
    var h = iter_slice_(m).copied().chain(iter_slice_(m).copied().take(1)).collect<[i32]>()
    hold("collect chain", h.size() == 6 && h.capacity() == 6 && h[5] == 1)
    var i = iter_slice_(m).enumerate().take(2).collect<[(usize, *const i32)]>()
    hold("collect enumerate", i.size() == 2 && i.capacity() == 2 && i[1].0 == 1 && *i[1].1 == 2)
    // A filter keeps no count: the vector grows as it is pushed to.
    var j = iter_slice_(m).copied().filter(is_even).collect<[i32]>()
    hold("collect filter", j.size() == 2 && j[0] == 2 && j[1] == 4)
    var k = iter(m.iter()).copied().map<i32>(triple).collect<[i32]>()
    hold("collect from the generator", k.size() == 5 && k[4] == 15)
    var s = iter_slice_(m).copied().map<i32>(triple).rev().sorted()
    hold("sorted", s.size() == 5 && s[0] == 3 && s[4] == 15)
}

/// Items with a destructor are built in the vector's raw slots.
fn owned_items() {
    var names: [string] = ["ab", "c", "def"]
    var view: [const string;] = names
    var loud = iter_slice_(view).map<string>(shout).collect<[string]>()
    hold("collect strings", loud.size() == 3 && loud.capacity() == 3 && loud[0] == "ab!" && loud[2] == "def!")
    var sizes = iter_slice_(view).rev().map<usize>(text_size).collect<[usize]>()
    hold("collect sizes", sizes.size() == 3 && sizes[0] == 3 && sizes[2] == 2)
    hold("join", iter_slice_(view).map<string>(shout).join("-") == "ab!-c!-def!")
}

/// Counts from `lo` up to `hi` (exclusive) at the front, down at the back.
class Span {
    var lo: i32
    var hi: i32

    pub fn Span(self, lo: i32, hi: i32) {
        self.lo = lo
        self.hi = hi
    }
}

extend Span impl DoubleEnded {
    type Item = i32
    fn next(self) -> i32? {
        if self.lo == self.hi {
            return null
        }

        self.lo += 1
        return self.lo - 1
    }
    fn next_back(self) -> i32? {
        if self.lo == self.hi {
            return null
        }

        self.hi -= 1
        return self.hi
    }
}

fn above_five(x: *const i32) -> bool = *x > 5

/// A chain read from the back: its second part first, then its first, and
/// the first part still there after a run that stopped in the second.
fn back_chain() {
    hold("chain backward", iter(Span(1, 4)).chain(Span(6, 9)).rev().fold<i64>(0, digits) == 876321)
    hold("chain backward, skip", iter(Span(1, 4)).chain(Span(6, 9)).rev().skip(2).fold<i64>(0, digits) == 6321)
    hold("chain backward, skip into the first part", iter(Span(1, 4)).chain(Span(6, 9)).rev().skip(4).fold<i64>(0, digits) == 21)
    hold("chain backward, skip_while", iter(Span(1, 4)).chain(Span(6, 9)).rev().skip_while(above_five).fold<i64>(0, digits) == 321)
    hold("chain backward, take", iter(Span(1, 4)).chain(Span(6, 9)).rev().take(4).fold<i64>(0, digits) == 8763)
    hold("chain backward, map", iter(Span(1, 4)).chain(Span(6, 9)).map<i32>(triple).rev().take(2).fold<i64>(0, digits) == 24 * 10 + 21)
    var found? = iter(Span(1, 4)).chain(Span(6, 9)).rev().find(is_even)
    hold("chain backward, find", found? && unwrap!(found) == 8)
    hold("rev of a chain's rev", iter(Span(1, 4)).chain(Span(6, 9)).rev().rev().fold<i64>(0, digits) == 123678)
}

fn main() -> i32 {
    back_chain()
    var many: [i32] = [1, 2, 3, 4, 5]
    ends(many)
    sizes()
    cuts(many)
    collects(many)
    owned_items()
    return if failed == 0 => 0 else => 1
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo_new -O2 %s -o %t.O2.exe --cache-dir %t.d
// RUN: %t.O2.exe
