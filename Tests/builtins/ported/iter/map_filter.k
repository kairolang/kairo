// `map`, `filter` and `filter_map`: results, laziness (nothing is pulled and
// no callback runs until a consumer asks, then once per item pulled and no
// more), reading from the back and from both ends (`map` and `filter` are
// DoubleEnded, `filter_map` is not), `remaining()` through `map`, and the
// move-only item that is delivered once, also when the chain is abandoned.
// `filter` and `filter_map` are not ExactSize: capabilities.k.
//
// Cases from Rust library/coretests/tests/iter/adapters/map.rs
//   (test_double_ended_map)
// Cases from Rust library/coretests/tests/iter/adapters/filter.rs and
//   adapters/filter_map.rs (the result, laziness and back cases)
// Cases from Rust library/coretests/tests/iter/traits/double_ended.rs
//   (test_rev with map and filter)

import std::iter::*
import std::io
import self::inputs::probe::*

fn <E impl Elem> map_results(const label: string) {
    reset()
    {
        var c = iter(Both<E>(4)).map<i64>(key_plus_100<E>)
        expect_pulls(0, 0, f"{label} map is lazy")
        expect(CALLS == 0, f"{label} map ran nothing")
        expect(c.remaining() == 4, f"{label} map remaining")
        expect_pulls(0, 0, f"{label} remaining pulls nothing")
        expect((c.next() ?? -1) == 100, f"{label} map first")
        expect_pulls(1, 0, f"{label} map pulled one")
        expect(CALLS == 1, f"{label} map ran once")
        expect(c.remaining() == 3, f"{label} map remaining after one")
        expect((c.next_back() ?? -1) == 103, f"{label} map back")
        expect(CALLS == 2 && c.remaining() == 2, f"{label} map back ran once")
        expect(ints_are(drain_keys(move(c)), [101, 102]), f"{label} map rest")
        expect(CALLS == 4, f"{label} map ran once per item")
    }

    expect_clean(f"{label} map")
    CALLS = 0

    reset()
    {
        expect(ints_are(drain_keys(iter(Both<E>(5)).map<i64>(key_of<E>).rev()), [4, 3, 2, 1, 0]), f"{label} map reversed")
        expect(CALLS == 5, f"{label} map reversed calls")
    }

    expect_clean(f"{label} map reversed")
    CALLS = 0

    reset()
    {
        expect(!iter(Both<E>(0)).map<i64>(key_of<E>).next()?, f"{label} map of nothing")
        expect(CALLS == 0, f"{label} map of nothing ran nothing")
    }

    expect_clean(f"{label} map empty")
    CALLS = 0
}

fn <E impl Elem> map_keeps_items_once(const label: string) {
    reset()
    {
        var v = drain_keys(iter(Both<E>(5)).map<E>(same<E>))
        expect(ints_are(v, [0, 1, 2, 3, 4]), f"{label} identity map")
    }

    expect_clean(f"{label} identity map")
    CALLS = 0

    reset()
    {
        var c = iter(Both<E>(5)).map<E>(same<E>)
        var a? = c.next()
        var b? = c.next_back()
        expect(a? && b?, f"{label} abandoned map items")
    }

    expect_clean(f"{label} abandoned map")
    CALLS = 0
}

fn to_text(x: i64) -> string = f"n{x}"
fn text_size(p: *const string) -> usize = p->size()

fn map_changes_type() {
    var v: [i64] = [1, 2, 3]
    var s = iter(v.iter()).copied().map<string>(to_text).collect<[string]>()
    expect(s.size() == 3 && s[0] == "n1" && s[2] == "n3", "map to string")
    var n = iter(s.iter()).map<usize>(text_size).sum()
    expect(n == 6, "map string to size")
}

fn <E impl Elem> filter_results(const label: string) {
    reset()
    {
        var c = iter(Both<E>(8)).filter(is_even<E>)
        expect_pulls(0, 0, f"{label} filter is lazy")
        expect(CALLS == 0, f"{label} filter ran nothing")
        expect(kor(c.next()) == 0, f"{label} filter first")
        expect_pulls(1, 0, f"{label} filter pulled one")
        expect(kor(c.next()) == 2, f"{label} filter second")
        expect_pulls(3, 0, f"{label} filter skipped one")
        expect(CALLS == 3, f"{label} filter tested each pulled item")
        expect(kor(c.next_back()) == 6, f"{label} filter back")
        expect_pulls(3, 2, f"{label} filter pulled two from the back")
        expect(kor(c.next_back()) == 4, f"{label} filter back again")
        expect_pulls(3, 4, f"{label} filter back skipped one")
        expect(kor(c.next()) == -1, f"{label} filter meets")
    }

    expect_clean(f"{label} filter")
    CALLS = 0

    reset()
    {
        var v = drain_keys(iter(Both<E>(9)).filter(is_odd<E>))
        expect(ints_are(v, [1, 3, 5, 7]), f"{label} filter drained")
        expect(CALLS == 9, f"{label} filter tested each item once")
    }

    expect_clean(f"{label} filter collect")
    CALLS = 0

    reset()
    {
        var v = drain_keys(iter(Both<E>(9)).filter(is_odd<E>).rev())
        expect(ints_are(v, [7, 5, 3, 1]), f"{label} filter reversed")
    }

    expect_clean(f"{label} filter reversed")
    CALLS = 0

    reset()
    {
        expect(!iter(Both<E>(0)).filter(is_odd<E>).next()?, f"{label} filter of nothing")
        expect(iter(Both<E>(1)).filter(is_odd<E>).count() == 0, f"{label} filter of one that fails")
        expect(iter(Both<E>(2)).filter(is_odd<E>).count() == 1, f"{label} filter of two")
        var two = drain_keys(iter(Both<E>(6)).filter(below_5<E>).filter(is_odd<E>).rev())
        expect(ints_are(two, [3, 1]), f"{label} two filters from the back")
    }

    expect_clean(f"{label} filter edges")
    CALLS = 0

    reset()
    {
        var c = iter(Both<E>(6)).filter(is_even<E>)
        var a? = c.next()
        var b? = c.next_back()
        expect(a? && b?, f"{label} filter abandoned items")
    }

    expect_clean(f"{label} filter abandoned")
    CALLS = 0
}

fn <E impl Elem> filter_map_results(const label: string) {
    reset()
    {
        var c = iter(Fwd<E>(9)).filter_map<E>(odd_only<E>)
        expect_pulls(0, 0, f"{label} filter_map is lazy")
        expect(CALLS == 0, f"{label} filter_map ran nothing")
        expect(kor(c.next()) == 1, f"{label} filter_map first")
        expect_pulls(2, 0, f"{label} filter_map pulled two")
        expect(kor(c.next()) == 3, f"{label} filter_map second")
        expect(CALLS == 4, f"{label} filter_map ran once per pulled item")
        var rest = drain_keys(move(c))
        expect(ints_are(rest, [5, 7]), f"{label} filter_map rest")
        expect(CALLS == 9, f"{label} filter_map ran once per item")
    }

    expect_clean(f"{label} filter_map")
    CALLS = 0

    reset()
    {
        var k = drain_keys(iter(Both<E>(10)).filter_map<i64>(third_key<E>))
        expect(ints_are(k, [0, 3, 6, 9]), f"{label} filter_map changes the type")
    }

    expect_clean(f"{label} filter_map to keys")
    CALLS = 0

    reset()
    {
        expect(iter(Fwd<E>(0)).filter_map<E>(odd_only<E>).count() == 0, f"{label} filter_map of nothing")
        expect(iter(Fwd<E>(4)).filter_map<i64>(third_key<E>).count() == 2, f"{label} filter_map count")
        var c = iter(Fwd<E>(6)).filter_map<E>(odd_only<E>)
        var a? = c.next()
        expect(a?, f"{label} filter_map abandoned item")
    }

    expect_clean(f"{label} filter_map edges")
    CALLS = 0
}

fn collect_move_only() {
    reset()
    {
        var m = iter(Both<Counted>(5)).map<Counted>(same<Counted>).collect<[Counted]>()
        var f = iter(Both<Counted>(7)).filter(is_odd<Counted>).collect<[Counted]>()
        var g = iter(Fwd<Counted>(7)).filter_map<Counted>(odd_only<Counted>).collect<[Counted]>()
        expect(keys_are(m, [0, 1, 2, 3, 4]), "map collects move-only items")
        expect(keys_are(f, [1, 3, 5]), "filter collects move-only items")
        expect(keys_are(g, [1, 3, 5]), "filter_map collects move-only items")
    }

    expect_clean("collected move-only items")
    CALLS = 0
}

fn even_square(x: i64) -> i64? {
    if x % 2 == 0 {
        return x * x
    }

    return null
}

fn ptr_even_square(p: *const i64) -> i64? {
    if *p % 2 == 0 {
        return *p * *p
    }

    return null
}

fn count_matching(acc: i64, x: i64) -> i64 = acc + 1

/// The inputs of the Rust filter_map and map tests.
fn rust_filter_map_cases() {
    var sq = iter(Both<i64>(10)).filter_map<i64>(even_square).collect<[i64]>()
    expect(ints_are(sq, [0, 4, 16, 36, 64]), "filter_map of even squares")
    var xs: [i64] = [0, 1, 2, 3, 4, 5, 6, 7, 8]
    var ys: [i64] = [0, 4, 16, 36, 64]
    var i: usize = 0
    var it = iter(xs.iter()).filter_map<i64>(ptr_even_square)
    loop {
        var x? = it.next()
        if !x? {
            break
        }

        expect(unwrap!(x) == ys[i], "filter_map item")
        i += 1
    }

    expect(i == ys.size(), "filter_map count")
    expect(iter(xs.iter()).filter_map<i64>(ptr_even_square).fold<i64>(0, count_matching) == 5, "filter_map fold")
}

fn composed() {
    var v: [i64] = [1, 2, 3, 4, 5, 6, 7, 8]
    var a = iter(v.iter()).copied().map<i64>(key_plus_100<i64>).filter(is_even<i64>).collect<[i64]>()
    expect(ints_are(a, [102, 104, 106, 108]), "map then filter")
    var b = iter(v.iter()).copied().filter(is_even<i64>).map<i64>(key_plus_100<i64>).collect<[i64]>()
    expect(ints_are(b, [102, 104, 106, 108]), "filter then map")
    var c = iter(v.iter()).copied().filter(below_5<i64>).map<i64>(key_plus_100<i64>).filter(is_odd<i64>).rev().collect<[i64]>()
    expect(ints_are(c, [103, 101]), "filter, map, filter, rev")
    var d = iter(v.iter()).copied().map<i64>(key_of<i64>).filter_map<i64>(third_key<i64>).collect<[i64]>()
    expect(ints_are(d, [3, 6]), "map then filter_map")
    CALLS = 0
}

fn main() -> i32 {
    map_results<i64>("i64")
    map_results<string>("string")
    map_results<Counted>("Counted")
    map_keeps_items_once<string>("string")
    map_keeps_items_once<Counted>("Counted")
    map_changes_type()
    filter_results<i64>("i64")
    filter_results<string>("string")
    filter_results<Counted>("Counted")
    filter_map_results<i64>("i64")
    filter_map_results<string>("string")
    filter_map_results<Counted>("Counted")
    collect_move_only()
    rust_filter_map_cases()
    composed()
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
