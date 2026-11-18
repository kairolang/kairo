// `flat_map`: the items of each sub-iterator in turn, empty sub-iterators in
// the middle, an empty outer source, laziness (the outer source is pulled
// only when the current sub-iterator has ended, a sub-iterator is not
// pulled again after its end and is released when it ends, not when the chain
// is), sub-iterators that are generators, and move-only items and
// sub-iterators abandoned half-way. `flat_map` is neither DoubleEnded nor
// ExactSize: capabilities.k.
//
// Cases from Rust library/coretests/tests/iter/adapters/flat_map.rs
//   (test_iterator_flat_map, test_iterator_flat_map_fold; the back-reading
//   case test_double_ended_flat_map has no counterpart: flat_map is
//   front-only here)

import std::iter::*
import std::io
import self::Inputs::probe::*

/// The sub-iterator of an item: a generator of `key` copies of the key.
fn repeat_key(x: i64) -> yield i64 {
    for var i: i64 = 0; i < x; i += 1 {
        yield x * 100 + i
    }
}

fn <E impl Elem> flat_results(const label: string) {
    // Outer items 0 1 2 3 give sub-iterators of 0 1 2 3 items: 0 | 0 1 | 0 1 2.
    reset()
    {
        var c = iter(Both<E>(4)).flat_map<Fwd<E>>(fwd_of<E, E>)
        expect_pulls(0, 0, f"{label} flat_map is lazy")
        expect(CALLS == 0, f"{label} flat_map ran nothing")
        expect(ints_are(drain_keys(move(c)), [0, 0, 1, 0, 1, 2]), f"{label} flat_map items")
        expect_pulls(5 + 1 + 2 + 3 + 4, 0, f"{label} flat_map pulls")
        expect(CALLS == 4, f"{label} flat_map ran once per outer item")
    }

    expect_clean(f"{label} flat_map")
    CALLS = 0

    reset()
    {
        var c = iter(Both<E>(4)).flat_map<Fwd<E>>(fwd_of<E, E>)
        expect(kor(c.next()) == 0, f"{label} first item")
        expect_pulls(2 + 2, 0, f"{label} first item pulled two outer and two inner")
        expect(CALLS == 2, f"{label} first item built two sub-iterators")
        expect(SOURCES == 2, f"{label} the outer source and the live sub-iterator")
        expect(kor(c.next()) == 0, f"{label} second item")
        expect(kor(c.next()) == 1, f"{label} third item")
        expect(SOURCES == 2, f"{label} still in the third sub-iterator")
    }

    expect_clean(f"{label} flat_map half-way")
    CALLS = 0

    reset()
    {
        var c = iter(Both<E>(3)).flat_map<Fwd<E>>(fwd_of<E, E>)
        expect(kor(c.next()) == 0 && kor(c.next()) == 0 && kor(c.next()) == 1, f"{label} up to the end of a sub-iterator")
        var n = c.next()
        expect(!n?, f"{label} flat_map ends")
        expect(SOURCES == 1, f"{label} sub-iterators are released when they end")
    }

    expect_clean(f"{label} flat_map released")
    CALLS = 0

    reset()
    {
        expect(iter(Both<E>(0)).flat_map<Fwd<E>>(fwd_of<E, E>).count() == 0, f"{label} flat_map of nothing")
        expect(iter(Both<E>(1)).flat_map<Fwd<E>>(fwd_of<E, E>).count() == 0, f"{label} flat_map of one empty sub-iterator")
        expect(iter(Both<E>(2)).flat_map<Both<E>>(both_of<E, E>).count() == 1, f"{label} flat_map to a DoubleEnded source")
    }

    expect_clean(f"{label} flat_map edges")
    CALLS = 0
}

fn flat_with_generators() {
    var v = iter(Both<i64>(4)).flat_map<yield i64>(repeat_key).collect<[i64]>()
    expect(ints_are(v, [100, 200, 201, 300, 301, 302]), "flat_map to generators")
    expect(iter(Both<i64>(0)).flat_map<yield i64>(repeat_key).count() == 0, "flat_map of nothing to generators")

    var c = iter(Both<i64>(4)).flat_map<yield i64>(repeat_key)
    expect((c.next() ?? -1) == 100 && (c.next() ?? -1) == 200, "flat_map to generators, partial")
}

fn flat_move_only() {
    reset()
    {
        var v = iter(Both<Counted>(5)).flat_map<Fwd<Counted>>(fwd_of<Counted, Counted>).collect<[Counted]>()
        expect(keys_are(v, [0, 0, 1, 0, 1, 2, 0, 1, 2, 3]), "flat_map collects move-only items")
    }

    expect_clean("collected flat_map")
    CALLS = 0

    reset()
    {
        var c = iter(Both<Counted>(5)).flat_map<Fwd<Counted>>(fwd_of<Counted, Counted>)
        var a? = c.next()
        var b? = c.next()
        var d? = c.next()
        expect(a? && b? && d?, "flat_map abandoned inside a sub-iterator")
    }

    expect_clean("abandoned flat_map")
    CALLS = 0

    reset()
    {
        var c = iter(Both<Counted>(2)).flat_map<Fwd<Counted>>(fwd_of<Counted, Counted>)
        var a? = c.next()
        expect(a?, "flat_map item")
        expect(SOURCES == 2, "outer and one sub-iterator alive")
    }

    expect_clean("flat_map dropped with both alive")
    CALLS = 0
}

fn flat_composed() {
    var a = iter(Both<i64>(5)).filter(is_even<i64>).flat_map<Fwd<i64>>(fwd_of<i64, i64>).collect<[i64]>()
    expect(ints_are(a, [0, 1, 0, 1, 2, 3]), "filter then flat_map")
    CALLS = 0
    var b = iter(Both<i64>(4)).flat_map<Fwd<i64>>(fwd_of<i64, i64>).skip(1).take(3).collect<[i64]>()
    expect(ints_are(b, [0, 1, 0]), "flat_map then skip then take")
    CALLS = 0
    var c = iter(Both<i64>(4)).flat_map<Fwd<i64>>(fwd_of<i64, i64>).enumerate().map<i64>(indexed<i64>).collect<[i64]>()
    expect(ints_are(c, [0, 1000, 2001, 3000, 4001, 5002]), "flat_map then enumerate")
    CALLS = 0
    var d = iter(Both<i64>(3)).flat_map<Fwd<i64>>(fwd_of<i64, i64>).chain(Both<i64>(2)).count()
    expect(d == 5, "flat_map then chain")
    CALLS = 0
}

fn range_of_three(x: i64) -> Both<i64> = Both<i64>(x, x + 3)
fn count_up(acc: i64, x: i64) -> i64 = acc + 1

/// The inputs of the Rust flat_map tests: items 0, 3, 6 each giving three.
fn rust_flat_map_cases() {
    var xs: [i64] = [0, 3, 6]
    var ys = iter(xs.iter()).copied().flat_map<Both<i64>>(range_of_three).collect<[i64]>()
    expect(ints_are(ys, [0, 1, 2, 3, 4, 5, 6, 7, 8]), "flat_map of three ranges")

    var c = iter(xs.iter()).copied().flat_map<Both<i64>>(range_of_three)
    expect((c.next() ?? -1) == 0, "flat_map first item")
    var rest = c.fold<i64>(0, count_up)
    expect(rest == 8, "fold after one item folds the rest")

    var d = iter(xs.iter()).copied().flat_map<Both<i64>>(range_of_three)
    d.next()
    d.next()
    expect(ints_are(d.collect<[i64]>(), [2, 3, 4, 5, 6, 7, 8]), "collect after two items")
}

fn main() -> i32 {
    flat_results<i64>("i64")
    flat_results<string>("string")
    flat_results<Counted>("Counted")
    flat_with_generators()
    flat_move_only()
    rust_flat_map_cases()
    flat_composed()
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
