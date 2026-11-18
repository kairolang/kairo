// The consumers that build a value: `collect` (into a vector, a set and a
// map), `partition`, `group_by`, `min`, `max`, `sorted`, `counts`, `sum` and
// `join`. Each is run on an empty source, on one item and on many; the
// order of the result is the documented one (`partition` and `group_by` keep
// the order pulled, `group_by` and `counts` key in order of first
// appearance, `min` is the first of several equal smallest items, `max` the
// last of several equal largest, `sorted` is stable), `sum` of nothing is
// `make_default()`, and `join` puts the separator between items only.
// A move-only item is delivered once whether it ends up in a result or is
// dropped on the way.
//
// Cases from Rust library/coretests/tests/iter/traits/accum.rs (sums)
// Cases from Rust library/coretests/tests/iter/traits/iterator.rs
//   (test_iterator_min, test_iterator_max, test_partition, test_collect)
// Cases from itertools tests/test_std.rs (join, sorted_by, minmax with
//   ties, counts) and tests/quick.rs (equal_partition, group map by key)

import std::iter::*
import std::io
import self::inputs::probe::*

fn collect_cases() {
    var none = iter(Both<i64>(0)).collect<[i64]>()
    var one = iter(Both<i64>(1)).collect<[i64]>()
    var many = iter(Both<i64>(9)).collect<[i64]>()
    var lazy = iter(Fwd<i64>(9)).collect<[i64]>()
    expect(none.size() == 0 && ints_are(one, [0]), "collect none and one")
    expect(ints_are(many, [0, 1, 2, 3, 4, 5, 6, 7, 8]), "collect many")
    expect(ints_are(lazy, [0, 1, 2, 3, 4, 5, 6, 7, 8]), "collect from a source of unknown length")
    expect(iter(Fwd<string>(3)).collect<[string]>().size() == 3, "collect strings")

    var big = iter(Fwd<i64>(1000)).collect<[i64]>()
    expect(big.size() == 1000 && big[0] == 0 && big[999] == 999 && big[500] == 500, "collect past several growths")

    var set = iter(Both<i64>(5)).map<i64>(mod3).collect<{i64}>()
    expect(set.size() == 3 && set.contains(0) && set.contains(1) && set.contains(2), "collect into a set drops duplicates")
    var no_set = iter(Both<i64>(0)).collect<{i64}>()
    expect(no_set.size() == 0, "collect into an empty set")

    var m = iter(Both<i64>(5)).map<(i64, string)>(entry).collect<{i64: string}>()
    expect(m.size() == 3, "collect into a map")
    expect(m[0] == "v3" && m[1] == "v4" && m[2] == "v2", "a later key replaces an earlier one")
    var order: [i64]
    for k in m.keys() {
        order.push(*k)
    }

    expect(ints_are(order, [0, 1, 2]), "the map keeps the order of first insertion")

    reset()
    {
        var c = iter(Both<Counted>(6)).collect<[Counted]>()
        var d = iter(Fwd<Counted>(6)).collect<[Counted]>()
        expect(keys_are(c, [0, 1, 2, 3, 4, 5]) && keys_are(d, [0, 1, 2, 3, 4, 5]), "collect move-only items")
        expect(c.size() == 6, "collect size")
    }

    expect_clean("collect move-only items")

    reset()
    {
        var c = iter(Both<Counted>(40)).collect<[Counted]>()
        var d = iter(Fwd<Counted>(40)).collect<[Counted]>()
        expect(c.size() == 40 && d.size() == 40 && c[39].get() == 39 && d[39].get() == 39, "collect enough move-only items to grow")
    }

    expect_clean("collect and grow move-only items")
}

fn mod3(x: i64) -> i64 = x % 3
fn entry(x: i64) -> (i64, string) = (x % 3, f"v{x}")

fn <E impl Elem> partition_cases(const label: string) {
    reset()
    {
        var p = iter(Both<E>(7)).partition(is_even<E>)
        expect(keys_are(p.0, [0, 2, 4, 6]) && keys_are(p.1, [1, 3, 5]), f"{label} partition")
        expect_pulls(8, 0, f"{label} partition pulls to the end once")
        expect(CALLS == 7, f"{label} partition tests each item once")
    }

    expect_clean(f"{label} partition")
    CALLS = 0

    reset()
    {
        var none = iter(Both<E>(0)).partition(is_even<E>)
        var one = iter(Both<E>(1)).partition(is_even<E>)
        var yes = iter(Both<E>(1)).skip(0).filter(any_key<E>).partition(any_key<E>)
        var no = iter(Both<E>(3)).partition(is_two<E>)
        expect(none.0.size() == 0 && none.1.size() == 0, f"{label} partition of nothing")
        expect(keys_are(one.0, [0]) && one.1.size() == 0, f"{label} partition of one")
        expect(yes.0.size() == 1 && yes.1.size() == 0, f"{label} partition where all hold")
        expect(keys_are(no.0, [2]) && keys_are(no.1, [0, 1]), f"{label} partition keeps each side's order")
    }

    expect_clean(f"{label} partition edges")
    CALLS = 0
}

fn <E impl Elem> group_cases(const label: string) {
    reset()
    {
        var g = iter(Both<E>(9)).group_by<i64>(key_mod3<E>)
        expect(g.size() == 3, f"{label} group_by groups")
        expect(keys_are(g[0], [0, 3, 6]) && keys_are(g[1], [1, 4, 7]) && keys_are(g[2], [2, 5, 8]), f"{label} each group in the order pulled")
        var order: [i64]
        for k in g.keys() {
            order.push(*k)
        }

        expect(ints_are(order, [0, 1, 2]), f"{label} keys in order of first appearance")
        expect(CALLS == 9, f"{label} group_by keys each item once")
    }

    expect_clean(f"{label} group_by")
    CALLS = 0

    reset()
    {
        var g = iter(Both<E>(0)).group_by<i64>(key_mod3<E>)
        expect(g.size() == 0, f"{label} group_by of nothing")
        var h = iter(Both<E>(1)).group_by<i64>(key_mod3<E>)
        expect(h.size() == 1 && keys_are(h[0], [0]), f"{label} group_by of one")
        var r = iter(Both<E>(6)).rev().group_by<i64>(key_mod3<E>)
        var order: [i64]
        for k in r.keys() {
            order.push(*k)
        }

        expect(ints_are(order, [2, 1, 0]) && keys_are(r[0], [3, 0]), f"{label} group_by of a reversed source")
    }

    expect_clean(f"{label} group_by edges")
    CALLS = 0
}

fn <E impl Elem> key_mod3(x: *const E) -> i64 {
    CALLS += 1
    return x->key() % 3
}

fn group_by_string_keys() {
    var words: [string] = ["pear", "fig", "plum", "kiwi", "apple", "lime", "date"]
    var g = iter(words.iter()).copied().group_by<usize>(word_length)
    expect(g.size() == 3, "groups by length")
    var order: [usize]
    for k in g.keys() {
        order.push(*k)
    }

    expect(order.size() == 3 && order[0] == 4 && order[1] == 3 && order[2] == 5, "length keys in order of first appearance")
    expect(g[4].size() == 5 && g[3].size() == 1 && g[5].size() == 1, "group sizes")
    expect(g[4][2] == "kiwi", "group order")
}

fn word_length(p: *const string) -> usize = p->size()

fn min_max_cases() {
    expect(!iter(Both<i64>(0)).min()? && !iter(Both<i64>(0)).max()?, "min and max of nothing")
    expect((iter(Both<i64>(1)).min() ?? -1) == 0 && (iter(Both<i64>(1)).max() ?? -1) == 0, "min and max of one")
    var v: [i64] = [4, -2, 9, 0, 9, -2, 3]
    var lo? = iter(v.iter()).copied().min()
    var hi? = iter(v.iter()).copied().max()
    expect(lo? && hi? && unwrap!(lo) == -2 && unwrap!(hi) == 9, "min and max of many")
    var w: [string] = ["pear", "apple", "fig", "zebra", "apple"]
    var wl? = iter(w.iter()).copied().min()
    var wh? = iter(w.iter()).copied().max()
    expect(wl? && wh? && unwrap!(wl) == "apple" && unwrap!(wh) == "zebra", "min and max of strings")
    var sk? = iter(v.iter()).copied().skip(2).take(3).min()
    expect(sk? && unwrap!(sk) == 0, "min after skip and take")

    reset()
    {
        iter(Both<i64>(6)).min()
        expect_pulls(7, 0, "min pulls to the end once")
        PULLS = 0
        iter(Both<i64>(6)).max()
        expect_pulls(7, 0, "max pulls to the end once")
    }

    expect_clean("min and max pulls")
}

fn min_max_ties() {
    reset()
    {
        var a: [Ranked]
        a.push(Ranked(2, 1))
        a.push(Ranked(1, 2))
        a.push(Ranked(3, 3))
        a.push(Ranked(1, 4))
        a.push(Ranked(3, 5))
        a.push(Ranked(2, 6))
        var lo? = iter(a.drain(0..a.size())).min()
        expect(lo? && unwrap!(lo).rank == 1 && unwrap!(lo).tag == 2, "min is the first of several equal smallest items")
    }

    expect_clean("min ties")

    reset()
    {
        var a: [Ranked]
        a.push(Ranked(2, 1))
        a.push(Ranked(1, 2))
        a.push(Ranked(3, 3))
        a.push(Ranked(1, 4))
        a.push(Ranked(3, 5))
        a.push(Ranked(2, 6))
        var hi? = iter(a.drain(0..a.size())).max()
        expect(hi? && unwrap!(hi).rank == 3 && unwrap!(hi).tag == 5, "max is the last of several equal largest items")
    }

    expect_clean("max ties")

    reset()
    {
        var a: [Ranked]
        a.push(Ranked(5, 1))
        var one? = iter(a.drain(0..a.size())).min()
        expect(one? && unwrap!(one).tag == 1, "min of one move-only item")
    }

    expect_clean("min of one")
}

fn sorted_cases() {
    expect(iter(Both<i64>(0)).sorted().size() == 0, "sorted of nothing")
    expect(ints_are(iter(Both<i64>(1)).sorted(), [0]), "sorted of one")
    var v: [i64] = [5, -1, 3, 3, 0, 9, -7, 3]
    expect(ints_are(iter(v.iter()).copied().sorted(), [-7, -1, 0, 3, 3, 3, 5, 9]), "sorted")
    var small: [i64] = [3, 4, 1, 2]
    expect(ints_are(iter(small.iter()).copied().sorted(), [1, 2, 3, 4]), "sorted four")
    expect(ints_are(iter(Both<i64>(5)).rev().sorted(), [0, 1, 2, 3, 4]), "sorted of a descending range")
    expect(ints_are(iter(v.iter()).copied().rev().sorted(), [-7, -1, 0, 3, 3, 3, 5, 9]), "sorted of a reversed source")
    expect(ints_are(iter(v.iter()).copied().filter(is_even<i64>).sorted(), [0]), "sorted through filter")
    var sorted_once = iter(Both<i64>(50)).rev().sorted()
    expect(sorted_once.size() == 50 && sorted_once[0] == 0 && sorted_once[49] == 49, "sorted of a descending source")
    var w: [string] = ["pear", "apple", "fig", "date", "apple"]
    var sw = iter(w.iter()).copied().sorted()
    expect(sw.size() == 5 && sw[0] == "apple" && sw[1] == "apple" && sw[2] == "date" && sw[4] == "pear", "sorted strings")
    expect(w[0] == "pear", "the source strings are intact")
    CALLS = 0

    reset()
    {
        var a: [Ranked]
        a.push(Ranked(2, 1))
        a.push(Ranked(1, 2))
        a.push(Ranked(2, 3))
        a.push(Ranked(1, 4))
        a.push(Ranked(0, 5))
        a.push(Ranked(2, 6))
        var s = iter(a.drain(0..a.size())).sorted()
        expect(ranked_are(s, [5, 102, 104, 201, 203, 206]), "sorted is stable for move-only items")
    }

    expect_clean("sorted move-only")
}

fn counts_cases() {
    expect(iter(Both<i64>(0)).counts().size() == 0, "counts of nothing")
    var one = iter(Both<i64>(1)).counts()
    expect(one.size() == 1 && one[0] == 1, "counts of one")
    var v: [i64] = [3, 1, 3, 2, 1, 3, 9]
    var c = iter(v.iter()).copied().counts()
    expect(c.size() == 4 && c[3] == 3 && c[1] == 2 && c[2] == 1 && c[9] == 1, "counts")
    var order: [i64]
    for k in c.keys() {
        order.push(*k)
    }

    expect(ints_are(order, [3, 1, 2, 9]), "counts keyed in order of first appearance")
    var w: [string] = ["a", "b", "a", "c", "b", "a"]
    var cw = iter(w.iter()).copied().counts()
    expect(cw.size() == 3 && cw["a"] == 3 && cw["b"] == 2 && cw["c"] == 1, "counts of strings")
    var cs = iter(Both<i64>(10)).map<i64>(mod3).counts()
    expect(cs.size() == 3 && cs[0] == 4 && cs[1] == 3 && cs[2] == 3, "counts through map")
}

fn sum_cases() {
    expect(iter(Both<i64>(0)).sum() == 0, "sum of nothing")
    expect(iter(Both<i64>(1)).sum() == 0, "sum of one")
    expect(iter(Both<i64>(11)).sum() == 55, "sum of many")
    var v: [i32] = [10, 20, 30, -5]
    expect(iter(v.iter()).copied().sum() == 55, "sum of i32")
    var e: [i32]
    expect(iter(e.iter()).copied().sum() == 0, "sum of an empty i32 chain")
    var f: [f64] = [0.5, 1.25, 2.0]
    expect(iter(f.iter()).copied().sum() == 3.75, "sum of f64")
    var g: [f64]
    expect(iter(g.iter()).copied().sum() == 0.0, "sum of an empty f64 chain")
    expect(iter(Both<i64>(10)).skip(2).take(3).sum() == 9, "sum after skip and take")
    expect(iter(Both<i64>(10)).filter(is_even<i64>).sum() == 20, "sum through filter")
    expect(iter(Both<i64>(4)).map<i64>(key_plus_100<i64>).sum() == 406, "sum through map")
    reset()
    {
        iter(Both<i64>(6)).sum()
        expect_pulls(7, 0, "sum pulls to the end once")
    }

    expect_clean("sum")
    CALLS = 0
}

fn join_cases() {
    expect(iter(Both<string>(0)).join(", ") == "", "join of nothing")
    expect(iter(Both<string>(1)).join(", ") == "e0", "join of one has no separator")
    expect(iter(Both<string>(4)).join(", ") == "e0, e1, e2, e3", "join with a separator")
    expect(iter(Both<string>(4)).join() == "e0e1e2e3", "join without a separator")
    expect(iter(Both<string>(3)).join("") == "e0e1e2", "join with an empty separator")
    expect(iter(Both<i64>(5)).join("-") == "0-1-2-3-4", "join of integers")
    expect(iter(Both<i64>(3)).map<i64>(key_plus_100<i64>).join("/") == "100/101/102", "join through map")
    expect(iter(Both<string>(3)).rev().join("") == "e2e1e0", "join of a reversed source")
    expect(iter(Both<string>(6)).filter(is_even<string>).join("+") == "e0+e2+e4", "join through filter")
    expect(iter(Both<i64>(3)).join("<>") == "0<>1<>2", "join with a long separator")

    var empty_items: [string] = ["", "", "x", ""]
    expect(iter(empty_items.iter()).copied().join(",") == ",,x,", "join keeps empty items")
    var w: [string] = ["héllo", "wörld"]
    expect(iter(w.iter()).copied().join(" ") == "héllo wörld", "join of non-ASCII strings")
    CALLS = 0
}

fn main() -> i32 {
    collect_cases()
    partition_cases<i64>("i64")
    partition_cases<string>("string")
    partition_cases<Counted>("Counted")
    group_cases<i64>("i64")
    group_cases<string>("string")
    group_cases<Counted>("Counted")
    group_by_string_keys()
    min_max_cases()
    min_max_ties()
    sorted_cases()
    counts_cases()
    sum_cases()
    join_cases()
    return finish()
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
