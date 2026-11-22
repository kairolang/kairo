// The scans that end at the first item a predicate decides (find, position,
// any, all, skip_while, counting a take_while), over a slice and over its
// rev(), give what a loop over the items gives wherever the deciding element
// sits: at every index of slices of every length from 0 to 110, which covers
// a scan that ends in the items tested one at a time, in a block, on a
// block's first and last element and in the items after the last whole
// block, and a scan with no deciding element. The predicates are named
// functions with no effect and no trap and the elements are numbers, so an
// optimized build tests a block at a time.
//
// A predicate with an effect is called once per item up to the deciding one
// and never after, as a loop over the items calls it; so is a predicate that
// divides by the element, which the zero elements past the deciding one
// would stop.
//
// What a skip_while passes on is read by a scan behind it (position, find,
// any, next): the first item passed is the one the skip stopped at, and the
// scan stops at a second mark behind it, with either mark in the items
// tested one at a time, on a block's first and last element and behind the
// last whole block.

import std::iter::*
import std::io

var failed: i32 = 0
var calls: usize = 0

fn hold(const end: string, const what: string, n: usize, at: usize, cond: bool) {
    if !cond {
        failed += 1
        if failed <= 20 {
            io::println(f"FAILED {end} {what} n={n} at={at}")
        }
    }
}

fn is_mark(p: *const (*const i32)) -> bool = **p == 5000
fn is_second(p: *const (*const i32)) -> bool = **p == 6000
fn not_mark(p: *const (*const i32)) -> bool = **p != 5000

fn counted_is_mark(p: *const (*const i32)) -> bool {
    calls += 1
    return **p == 5000
}

fn counted_not_mark(p: *const (*const i32)) -> bool {
    calls += 1
    return **p != 5000
}

/// False for 100, and a crash for 0.
fn quotient_not_ten(p: *const (*const i32)) -> bool = (1000 / **p) != 10
fn quotient_is_ten(p: *const (*const i32)) -> bool = (1000 / **p) == 10

/// `n` elements, none of them 5000 or 0, with 5000 at `at` when `at < n`.
fn marked(n: usize, at: usize) -> [i32] {
    var v: [i32]
    for var i: usize = 0; i < n; i += 1 {
        v.push((i as i32) * 7 + 1)
    }

    if at < n {
        v[at] = 5000
    }

    return v
}

/// What the scans must give for a deciding element `at` items from the end
/// the scan starts at (`at == n`: none).
fn pure_scans(const label: string, const s: [const i32;], n: usize, at: usize, back: bool) {
    var hit = at < n
    var lead = if hit => at else => n
    var cnt: usize = 0
    var pos: usize? = null
    var found: (*const i32)? = null
    var some = false
    var every = false
    var rest: usize = 0
    if back {
        rest = iter(s.iter()).rev().skip_while(not_mark).count()
        cnt = iter(s.iter()).rev().take_while(not_mark).count()
        pos = iter(s.iter()).rev().position(is_mark)
        found = iter(s.iter()).rev().find(is_mark)
        some = iter(s.iter()).rev().any(is_mark)
        every = iter(s.iter()).rev().all(not_mark)
    } else {
        rest = iter(s.iter()).skip_while(not_mark).count()
        cnt = iter(s.iter()).take_while(not_mark).count()
        pos = iter(s.iter()).position(is_mark)
        found = iter(s.iter()).find(is_mark)
        some = iter(s.iter()).any(is_mark)
        every = iter(s.iter()).all(not_mark)
    }

    hold(label, "take_while count", n, at, cnt == lead)
    hold(label, "skip_while count", n, at, rest == n - lead)
    hold(label, "position", n, at, pos? == hit && (pos ?? n) == lead)
    hold(label, "any", n, at, some == hit)
    hold(label, "all", n, at, every == !hit)
    if hit {
        var want: *const i32 = if back => &s[n - 1 - at] else => &s[at]
        hold(label, "find", n, at, found? && unwrap!(found) == want)
    } else {
        hold(label, "find", n, at, !found?)
    }
}

/// The same scans with a predicate that counts its calls: one call per item
/// up to the deciding one, which is `at + 1` calls, or `n` when there is none.
fn counted_scans(const label: string, const s: [const i32;], n: usize, at: usize, back: bool) {
    var hit = at < n
    var lead = if hit => at else => n
    var want = if hit => at + 1 else => n
    var cnt: usize = 0
    var pos: usize? = null
    calls = 0
    if back {
        cnt = iter(s.iter()).rev().take_while(counted_not_mark).count()
    } else {
        cnt = iter(s.iter()).take_while(counted_not_mark).count()
    }

    hold(label, "counted take_while", n, at, cnt == lead && calls == want)
    calls = 0
    if back {
        pos = iter(s.iter()).rev().position(counted_is_mark)
    } else {
        pos = iter(s.iter()).position(counted_is_mark)
    }

    hold(label, "counted position", n, at, (pos ?? n) == lead && calls == want)
    calls = 0
    var found = if back => iter(s.iter()).rev().find(counted_is_mark) else => iter(s.iter()).find(counted_is_mark)
    hold(label, "counted find", n, at, found? == hit && calls == want)
    calls = 0
    var some = if back => iter(s.iter()).rev().any(counted_is_mark) else => iter(s.iter()).any(counted_is_mark)
    hold(label, "counted any", n, at, some == hit && calls == want)
    calls = 0
    var every = if back => iter(s.iter()).rev().all(counted_not_mark) else => iter(s.iter()).all(counted_not_mark)
    hold(label, "counted all", n, at, every == !hit && calls == want)
    calls = 0
    var rest = if back => iter(s.iter()).rev().skip_while(counted_not_mark).count() else => iter(s.iter()).skip_while(counted_not_mark).count()
    hold(label, "counted skip_while", n, at, rest == n - lead && calls == want)
}

fn every_position() {
    for var n: usize = 0; n <= 110; n += 1 {
        for var at: usize = 0; at <= n; at += 1 {
            var front = marked(n, at)
            pure_scans("front", front, n, at, false)
            counted_scans("front", front, n, at, false)
            var back = marked(n, if at < n => n - 1 - at else => n)
            pure_scans("back", back, n, at, true)
            counted_scans("back", back, n, at, true)
        }
    }
}

/// 100 ends each scan; the zeros behind it would stop the program if the
/// predicate reached them.
fn divisor_past_the_end() {
    for var at: usize = 0; at < 100; at += 9 {
        var front: [i32]
        var back: [i32]
        for var i: usize = 0; i < 100; i += 1 {
            front.push(if i < at => 7 else => (if i == at => 100 else => 0))
            back.push(if i > 99 - at => 7 else => (if i == 99 - at => 100 else => 0))
        }

        var f: [const i32;] = front
        var b: [const i32;] = back
        hold("divisor", "take_while", 100, at, iter(f.iter()).take_while(quotient_not_ten).count() == at)
        hold("divisor", "position", 100, at, (iter(f.iter()).position(quotient_is_ten) ?? 100) == at)
        hold("divisor", "any", 100, at, iter(f.iter()).any(quotient_is_ten))
        hold("divisor", "all", 100, at, !iter(f.iter()).all(quotient_not_ten))
        hold("divisor", "find", 100, at, *(iter(f.iter()).find(quotient_is_ten) ?? &f[0]) == 100)
        hold("divisor", "rev take_while", 100, at, iter(b.iter()).rev().take_while(quotient_not_ten).count() == at)
        hold("divisor", "rev position", 100, at, (iter(b.iter()).rev().position(quotient_is_ten) ?? 100) == at)
    }
}

/// The scans behind a skip_while, for a first mark `at` items from the end
/// the scan starts at (`at == n`: none) and a second one `gap` items behind
/// it when `second`.
fn skipped_scans(const label: string,
                 const s: [const i32;],
                 n: usize,
                 at: usize,
                 gap: usize,
                 second: bool,
                 back: bool) {
    var hit = at < n
    var pos: usize? = null
    var again: usize? = null
    var found: (*const i32)? = null
    var first: (*const i32)? = null
    var some = false
    if back {
        pos = iter(s.iter()).rev().skip_while(not_mark).position(is_second)
        again = iter(s.iter()).rev().skip_while(not_mark).position(is_mark)
        found = iter(s.iter()).rev().skip_while(not_mark).find(is_second)
        some = iter(s.iter()).rev().skip_while(not_mark).any(is_second)
        var t = iter(s.iter()).rev().skip_while(not_mark)
        first = t.next()
    } else {
        pos = iter(s.iter()).skip_while(not_mark).position(is_second)
        again = iter(s.iter()).skip_while(not_mark).position(is_mark)
        found = iter(s.iter()).skip_while(not_mark).find(is_second)
        some = iter(s.iter()).skip_while(not_mark).any(is_second)
        var t = iter(s.iter()).skip_while(not_mark)
        first = t.next()
    }

    hold(label, "skip_while position", n, at, pos? == second && (pos ?? gap) == gap)
    hold(label, "skip_while position of the first", n, at, again? == hit && (again ?? 0) == 0)
    hold(label, "skip_while any", n, at, some == second)
    if second {
        var want: *const i32 = if back => &s[n - 1 - at - gap] else => &s[at + gap]
        hold(label, "skip_while find", n, at, found? && unwrap!(found) == want)
    } else {
        hold(label, "skip_while find", n, at, !found?)
    }

    if hit {
        var want: *const i32 = if back => &s[n - 1 - at] else => &s[at]
        hold(label, "skip_while next", n, at, first? && unwrap!(first) == want)
    } else {
        hold(label, "skip_while next", n, at, !first?)
    }
}

/// Lengths with no block, one block exactly, one item over, and several
/// blocks; the first mark at every index; the second one next to it, a
/// block behind it, one item to either side of that, or absent.
fn skip_while_then_scan() {
    for var n: usize = 0; n <= 110; n += 1 {
        if n > 1 && (n < 39 || n > 41) && n != 72 && n != 73 && n != 110 {
            continue
        }

        for var at: usize = 0; at <= n; at += 1 {
            for var gap: usize = 0; gap <= 33; gap += 1 {
                if gap >= 3 && gap <= 30 {
                    continue
                }

                var second = gap != 0 && at + gap < n
                var front = marked(n, at)
                var back = marked(n, if at < n => n - 1 - at else => n)
                if second {
                    front[at + gap] = 6000
                    back[n - 1 - at - gap] = 6000
                }

                skipped_scans("front", front, n, at, gap, second, false)
                skipped_scans("back", back, n, at, gap, second, true)
            }
        }
    }
}

/// Elements that are records keep the loop over the items; the answers are
/// the same.
struct Cell {
    var v: i32
}

fn cell_is_mark(p: *const (*const Cell)) -> bool = (*p)->v == 5000

fn records() {
    var cells: [Cell]
    for var i: i32 = 0; i < 100; i += 1 {
        cells.push(Cell { v: if i == 70 => 5000 else => i })
    }

    var s: [const Cell;] = cells
    hold("record", "position", 100, 70, (iter(s.iter()).position(cell_is_mark) ?? 100) == 70)
    hold("record", "rev position", 100, 70, (iter(s.iter()).rev().position(cell_is_mark) ?? 100) == 29)
    hold("record", "any", 100, 70, iter(s.iter()).any(cell_is_mark))
}

fn main() -> i32 {
    every_position()
    divisor_past_the_end()
    skip_while_then_scan()
    records()
    return if failed == 0 => 0 else => 1
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.O2.exe %t.O3.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo -O2 %s -o %t.O2.exe --cache-dir %t.d
// RUN: %t.O2.exe
// RUN: rm -rf %t.d
// RUN: %kairo -O3 %s -o %t.O3.exe --cache-dir %t.d
// RUN: %t.O3.exe
