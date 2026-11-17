// The consumers, each over no item, one item and several: fold, reduce,
// count, last, nth, find, position, any, all, for_each, partition,
// group_by, min, max, sorted, counts, sum, join, and collect into a vector,
// a map and a set.

import std::iter::*
import std::io

var failed: i32 = 0
var seen: i64 = 0

fn hold(const label: string, cond: bool) {
    if !cond {
        failed += 1
        io::println(f"FAILED {label}")
    }
}

fn upto(n: i64) -> yield i64 {
    for var i: i64 = 0; i < n; i += 1 {
        yield i
    }
}

/// 3 1 4 1 5 9 2 6, cut to the first `n`.
fn digits(n: usize) -> yield i64 {
    var d: [i64] = [3, 1, 4, 1, 5, 9, 2, 6]
    for var i: usize = 0; i < n && i < d.size(); i += 1 {
        yield d[i]
    }
}

fn words(n: i32) -> yield string {
    if n > 0 {
        yield "pear"
    }

    if n > 1 {
        yield "fig"
    }

    if n > 2 {
        yield "plum"
    }
}

fn add(a: i64, x: i64) -> i64 = a + x
fn larger(a: i64, b: i64) -> i64 = if a > b => a else => b
fn even(x: *const i64) -> bool = (*x & 1) == 0
fn is_four(x: *const i64) -> bool = *x == 4
fn is_seven(x: *const i64) -> bool = *x == 7
fn below_ten(x: *const i64) -> bool = *x < 10
fn note(x: i64) { seen = seen * 10 + x }
fn parity(x: *const i64) -> i64 = *x & 1
fn length(x: *const string) -> usize = x->size()
fn keyed(x: i64) -> (i64, i64) = (x, x * x)

fn folds() {
    hold("fold 0", iter(upto(0)).fold<i64>(7, add) == 7)
    hold("fold 1", iter(upto(1)).fold<i64>(7, add) == 7)
    hold("fold n", iter(upto(5)).fold<i64>(7, add) == 17)
    hold("reduce 0", !iter(upto(0)).reduce(add)?)
    hold("reduce 1", (iter(digits(1)).reduce(add) ?? -1) == 3)
    hold("reduce n", (iter(digits(8)).reduce(larger) ?? -1) == 9)
    hold("sum 0", iter(upto(0)).sum() == 0)
    hold("sum 1", iter(digits(1)).sum() == 3)
    hold("sum n", iter(digits(8)).sum() == 31)
    hold("count 0", iter(upto(0)).count() == 0)
    hold("count 1", iter(upto(1)).count() == 1)
    hold("count n", iter(upto(6)).count() == 6)
    hold("count filtered", iter(upto(6)).filter(even).count() == 3)
}

fn picks() {
    hold("last 0", !iter(upto(0)).last()?)
    hold("last 1", (iter(digits(1)).last() ?? -1) == 3)
    hold("last n", (iter(digits(8)).last() ?? -1) == 6)
    hold("nth 0 of 0", !iter(upto(0)).nth(0)?)
    hold("nth 0", (iter(digits(8)).nth(0) ?? -1) == 3)
    hold("nth n", (iter(digits(8)).nth(5) ?? -1) == 9)
    hold("nth last", (iter(digits(8)).nth(7) ?? -1) == 6)
    hold("nth past the end", !iter(digits(8)).nth(8)?)
    hold("find 0", !iter(upto(0)).find(is_four)?)
    hold("find hit", (iter(digits(8)).find(even) ?? -1) == 4)
    hold("find miss", !iter(digits(8)).find(is_seven)?)
    hold("position 0", !iter(upto(0)).position(is_four)?)
    hold("position hit", (iter(digits(8)).position(is_four) ?? 99) == 2)
    hold("position first", (iter(digits(8)).position(below_ten) ?? 99) == 0)
    hold("position miss", !iter(digits(8)).position(is_seven)?)
    hold("any 0", !iter(upto(0)).any(even))
    hold("any hit", iter(digits(8)).any(is_four))
    hold("any miss", !iter(digits(8)).any(is_seven))
    hold("all 0", iter(upto(0)).all(even))
    hold("all hold", iter(digits(8)).all(below_ten))
    hold("all fail", !iter(digits(8)).all(even))
    hold("min 0", !iter(upto(0)).min()?)
    hold("min 1", (iter(digits(1)).min() ?? -1) == 3)
    hold("min n", (iter(digits(8)).min() ?? -1) == 1)
    hold("max 0", !iter(upto(0)).max()?)
    hold("max 1", (iter(digits(1)).max() ?? -1) == 3)
    hold("max n", (iter(digits(8)).max() ?? -1) == 9)
    seen = 0
    iter(upto(0)).for_each(note)
    hold("for_each 0", seen == 0)
    iter(digits(4)).for_each(note)
    hold("for_each n", seen == 3141)
}

fn collections() {
    var none = iter(upto(0)).collect<[i64]>()
    var one = iter(digits(1)).collect<[i64]>()
    var many = iter(digits(8)).collect<[i64]>()
    hold("collect 0", none.size() == 0)
    hold("collect 1", one.size() == 1 && one[0] == 3)
    hold("collect n", many.size() == 8 && many[0] == 3 && many[5] == 9 && many[7] == 6)

    var s0 = iter(upto(0)).sorted()
    var sn = iter(digits(8)).sorted()
    hold("sorted 0", s0.size() == 0)
    hold("sorted n", sn.size() == 8 && sn[0] == 1 && sn[1] == 1 && sn[2] == 2 && sn[7] == 9)

    var p0 = iter(upto(0)).partition(even)
    var pn = iter(digits(8)).partition(even)
    hold("partition 0", p0.0.size() == 0 && p0.1.size() == 0)
    hold("partition n", pn.0.size() == 3 && pn.1.size() == 5)
    hold("partition order", pn.0[0] == 4 && pn.0[2] == 6 && pn.1[0] == 3 && pn.1[4] == 9)

    var g0 = iter(upto(0)).group_by<i64>(parity)
    var gn = iter(digits(8)).group_by<i64>(parity)
    hold("group_by 0", g0.size() == 0)
    hold("group_by n", gn.size() == 2 && gn[1].size() == 5 && gn[0].size() == 3)
    hold("group_by order", gn[1][0] == 3 && gn[1][4] == 9 && gn[0][0] == 4 && gn[0][2] == 6)
    var gw = iter(words(3)).group_by<usize>(length)
    hold("group_by strings", gw.size() == 2 && gw[4].size() == 2 && gw[3].size() == 1 && gw[4][1] == "plum")

    var c0 = iter(upto(0)).counts()
    var cn = iter(digits(8)).counts()
    hold("counts 0", c0.size() == 0)
    hold("counts n", cn.size() == 7 && cn[1] == 2 && cn[3] == 1 && cn[9] == 1)
    var cw = iter(words(3)).chain(words(1)).counts()
    hold("counts strings", cw.size() == 3 && cw["pear"] == 2 && cw["fig"] == 1)

    var m = iter(upto(4)).map<(i64, i64)>(keyed).collect<{i64: i64}>()
    hold("collect a map", m.size() == 4 && m[3] == 9 && m[0] == 0)
    var set = iter(digits(8)).collect<{i64}>()
    hold("collect a set", set.size() == 7)
}

fn joins() {
    hold("join 0", iter(words(0)).join(", ") == "")
    hold("join 1", iter(words(1)).join(", ") == "pear")
    hold("join n", iter(words(3)).join(", ") == "pear, fig, plum")
    hold("join no separator", iter(words(3)).join() == "pearfigplum")
    hold("join numbers", iter(digits(4)).join("-") == "3-1-4-1")
}

fn main() -> i32 {
    folds()
    picks()
    collections()
    joins()
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
