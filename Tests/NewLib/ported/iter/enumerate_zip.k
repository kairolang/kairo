// `enumerate` and `zip`: the pairs they make, laziness, `remaining()` (the
// shorter side for `zip`), reading from the back (an enumerated item keeps
// the index it has from the front; a zip drops the extra items of the longer
// side first), unequal lengths from both ends, a zip with a source that is
// only an Iterator, and move-only items in either half of a pair.
//
// Cases from Rust library/coretests/tests/iter/adapters/enumerate.rs
//   (test_iterator_enumerate, test_iterator_enumerate_nth,
//   test_iterator_enumerate_count, test_double_ended_enumerate,
//   test_empty_iterator_enumerate_next_index)
// Cases from Rust library/coretests/tests/iter/adapters/zip.rs
//   (test_zip_nth, test_double_ended_zip, test_zip_next_back_side_effects,
//   test_zip_map_rev_sideffectful)

import std::iter::*
import std::io
import self::Inputs::probe::*

fn <E impl Elem> enumerate_front(const label: string) {
    reset()
    {
        var c = iter(Both<E>(4)).enumerate().map<i64>(indexed<E>)
        expect_pulls(0, 0, f"{label} enumerate is lazy")
        expect(c.remaining() == 4, f"{label} enumerate remaining")
        expect(ints_are(drain_keys(move(c)), [0, 1001, 2002, 3003]), f"{label} enumerate pairs")
        expect_pulls(5, 0, f"{label} enumerate pulled each item once")
    }

    expect_clean(f"{label} enumerate")
    CALLS = 0

    reset()
    {
        var c = iter(Both<E>(0)).enumerate()
        expect(c.remaining() == 0 && !c.next()?, f"{label} enumerate of nothing")
    }

    expect_clean(f"{label} enumerate empty")
}

fn <E impl Elem> enumerate_back(const label: string) {
    reset()
    {
        var c = iter(Both<E>(4)).enumerate().map<i64>(indexed<E>).rev()
        expect(ints_are(drain_keys(move(c)), [3003, 2002, 1001, 0]), f"{label} enumerate reversed")
        expect_pulls(0, 5, f"{label} enumerate reversed pulls")
    }

    expect_clean(f"{label} enumerate reversed")
    CALLS = 0

    reset()
    {
        var c = iter(Both<E>(6)).enumerate()
        var a? = c.next()
        var b? = c.next_back()
        var d? = c.next()
        var e? = c.next_back()
        expect(a? && b? && d? && e?, f"{label} enumerate both ends")
        expect(unwrap!(a).0 == 0 && unwrap!(a).1.key() == 0, f"{label} enumerate front pair")
        expect(unwrap!(b).0 == 5 && unwrap!(b).1.key() == 5, f"{label} enumerate back pair")
        expect(unwrap!(d).0 == 1 && unwrap!(e).0 == 4, f"{label} enumerate indexes after both ends")
        expect(c.remaining() == 2, f"{label} enumerate remaining after four")
    }

    expect_clean(f"{label} enumerate both ends")
}

fn <E impl Elem> enumerate_after_skip(const label: string) {
    reset()
    {
        var c = iter(Both<E>(6)).skip(2).enumerate().map<i64>(indexed<E>)
        expect(ints_are(drain_keys(move(c)), [2, 1003, 2004, 3005]), f"{label} enumerate counts from the skip")
    }

    expect_clean(f"{label} skip then enumerate")
    CALLS = 0

    reset()
    {
        var c = iter(Both<E>(6)).enumerate().skip(2).map<i64>(indexed<E>)
        expect(ints_are(drain_keys(move(c)), [2002, 3003, 4004, 5005]), f"{label} enumerate then skip keeps the index")
    }

    expect_clean(f"{label} enumerate then skip")
    CALLS = 0
}

fn <E impl Elem, F impl Elem> zip_equal(const label: string) {
    reset()
    {
        var c = iter(Both<E>(4)).zip(Both<F>(4)).map<i64>(paired<E, F>)
        expect_pulls(0, 0, f"{label} zip is lazy")
        expect(c.remaining() == 4, f"{label} zip remaining")
        expect(ints_are(drain_keys(move(c)), [0, 1001, 2002, 3003]), f"{label} zip pairs")
    }

    expect_clean(f"{label} zip")
    CALLS = 0

    reset()
    {
        var c = iter(Both<E>(4)).zip(Both<F>(4)).map<i64>(paired<E, F>).rev()
        expect(ints_are(drain_keys(move(c)), [3003, 2002, 1001, 0]), f"{label} zip reversed")
    }

    expect_clean(f"{label} zip reversed")
    CALLS = 0
}

fn <E impl Elem, F impl Elem> zip_unequal(const label: string) {
    // The first side is longer.
    reset()
    {
        var c = iter(Both<E>(5)).zip(Both<F>(3))
        expect(c.remaining() == 3, f"{label} zip remaining is the shorter side (long first)")
        expect(ints_are(drain_keys(iter(Both<E>(5)).zip(Both<F>(3)).map<i64>(paired<E, F>)), [0, 1001, 2002]), f"{label} zip stops with the shorter (long first)")
    }

    expect_clean(f"{label} zip long first")
    CALLS = 0

    // The second side is longer.
    reset()
    {
        var c = iter(Both<E>(2)).zip(Both<F>(6))
        expect(c.remaining() == 2, f"{label} zip remaining is the shorter side (long second)")
        expect(ints_are(drain_keys(move(c).map<i64>(paired<E, F>)), [0, 1001]), f"{label} zip stops with the shorter (long second)")
    }

    expect_clean(f"{label} zip long second")
    CALLS = 0

    // From the back the extra items of the longer side are dropped first.
    reset()
    {
        var c = iter(Both<E>(5)).zip(Both<F>(3)).map<i64>(paired<E, F>).rev()
        expect(ints_are(drain_keys(move(c)), [2002, 1001, 0]), f"{label} zip reversed, long first")
    }

    expect_clean(f"{label} zip reversed long first")
    CALLS = 0

    reset()
    {
        var c = iter(Both<E>(2)).zip(Both<F>(6)).map<i64>(paired<E, F>).rev()
        expect(ints_are(drain_keys(move(c)), [1001, 0]), f"{label} zip reversed, long second")
    }

    expect_clean(f"{label} zip reversed long second")
    CALLS = 0

    // Alternating ends over unequal lengths.
    reset()
    {
        var c = iter(Both<E>(6)).zip(Both<F>(4)).map<i64>(paired<E, F>)
        var a = c.next() ?? -1
        var b = c.next_back() ?? -1
        var d = c.next() ?? -1
        var e = c.next_back() ?? -1
        var f = c.next() ?? -1
        expect(a == 0 && b == 3003 && d == 1001 && e == 2002 && f == -1, f"{label} zip alternating, unequal")
        expect(c.remaining() == 0, f"{label} zip remaining at the end")
    }

    expect_clean(f"{label} zip alternating unequal")
    CALLS = 0

    // Zip with an empty side.
    reset()
    {
        var c = iter(Both<E>(0)).zip(Both<F>(3))
        expect(c.remaining() == 0 && !c.next()?, f"{label} zip with an empty first side")
        var d = iter(Both<E>(3)).zip(Both<F>(0))
        expect(d.remaining() == 0 && !d.next_back()?, f"{label} zip with an empty second side, from the back")
        var e = iter(Both<E>(3)).zip(Both<F>(0))
        expect(!e.next()?, f"{label} zip with an empty second side, from the front")
    }

    expect_clean(f"{label} zip with an empty side")
}

fn zip_pulls() {
    // `a` is pulled first; the item pulled from `a` when `b` has ended is
    // dropped, and neither side is asked again after its end.
    reset()
    {
        var c = iter(Fwd<Counted>(5)).zip(Fwd<Counted>(2))
        var n = 0
        loop {
            var x? = c.next()
            if !x? {
                break
            }

            n += 1
        }

        expect(n == 2, "zip of 5 and 2 pairs two")
        expect_pulls(3 + 3, 0, "zip pulls three from each side")
    }

    expect_clean("zip pulls")

    reset()
    {
        var c = iter(Fwd<i64>(2)).zip(Fwd<i64>(5))
        var n = 0
        while c.next()? {
            n += 1
        }

        expect(n == 2, "zip of 2 and 5 pairs two")
        expect_pulls(3 + 2, 0, "the longer second side is asked twice")
    }

    expect_clean("zip pulls second longer")

    reset()
    {
        var c = iter(Fwd<i64>(2)).zip(Both<i64>(5))
        var a? = c.next()
        expect_pulls(2, 0, "zip of two sources pulls once from each")
        expect(a?, "zip pair")
    }

    expect_clean("zip of an Iterator and a DoubleEnded")
}

fn zip_with_slices() {
    var a: [i64] = [1, 2, 3, 4]
    var b: [string] = ["w", "x", "y"]
    var c = iter(a.iter()).zip(b.iter())
    expect(c.remaining() == 3, "zip of two slice iterators")
    var p? = c.next_back()
    expect(p? && *unwrap!(p).0 == 3 && *unwrap!(p).1 == "y", "zip of slices from the back")
    var q? = c.next()
    expect(q? && *unwrap!(q).0 == 1 && *unwrap!(q).1 == "w", "zip of slices from the front")
    expect(c.remaining() == 1, "zip of slices remaining")

    var total: i64 = 0
    for var i: i64 = 0; i < 3; ++i {
        total += i
    }

    var z = iter(a.iter()).copied().zip(b.iter()).enumerate().count()
    expect(z == 3, "zip then enumerate counts the shorter side")
}

fn move_only_pairs() {
    reset()
    {
        var c = iter(Both<Counted>(4)).zip(Both<Counted>(6)).enumerate().rev()
        var a? = c.next()
        var b? = c.next()
        expect(a? && b?, "move-only pairs delivered")
        expect(unwrap!(a).0 == 3 && unwrap!(a).1.0.get() == 3 && unwrap!(a).1.1.get() == 3, "enumerate of zip, last item")
        expect(unwrap!(b).0 == 2, "enumerate of zip, second to last")
    }

    expect_clean("move-only pairs abandoned")

    reset()
    {
        var v = iter(Both<Counted>(3)).zip(Both<string>(3)).collect<[(Counted, string)]>()
        expect(v.size() == 3 && v[2].0.get() == 2 && v[1].1 == "e1", "collected pairs")
    }

    expect_clean("collected pairs")
}

static LOGA: [i64; 16]
static LOGB: [i64; 16]
static NA: usize = 0
static NB: usize = 0
static XS: [i64; 8]
static YS: [i64; 8]

fn log_a(n: i64) -> i64 {
    LOGA[NA] = n
    NA += 1
    return n * 10
}

fn log_b(n: i64) -> i64 {
    LOGB[NB] = n * 100
    NB += 1
    return n * 1000
}

fn bump_x(i: i64) -> i64 {
    XS[i as usize] += 1
    return i
}

fn bump_y(i: i64) -> i64 {
    YS[i as usize] += 1
    return i
}

fn clear_logs() {
    NA = 0
    NB = 0
    for var i: usize = 0; i < 8; ++i {
        XS[i] = 0
        YS[i] = 0
    }
}

fn log_a_is(const want: [i64]) -> bool {
    if NA != want.size() {
        return false
    }

    for var i: usize = 0; i < NA; ++i {
        if LOGA[i] != want[i] {
            return false
        }
    }

    return true
}

fn log_b_is(const want: [i64]) -> bool {
    if NB != want.size() {
        return false
    }

    for var i: usize = 0; i < NB; ++i {
        if LOGB[i] != want[i] {
            return false
        }
    }

    return true
}

fn xs_are(const want: [i64]) -> bool {
    for var i: usize = 0; i < want.size(); ++i {
        if XS[i] != want[i] {
            return false
        }
    }

    return true
}

fn ys_are(const want: [i64]) -> bool {
    for var i: usize = 0; i < want.size(); ++i {
        if YS[i] != want[i] {
            return false
        }
    }

    return true
}

/// Side effects of the callbacks under a zip. The first side is pulled first
/// and the item it gives when the second side has ended is dropped
/// (Lib/std2/iter.k, `Zip`); from the back the longer side is trimmed first.
fn rust_zip_side_effects() {
    // The second side is one item longer: trimmed from the back.
    clear_logs()
    {
        var c = iter(Both<i64>(1, 7)).map<i64>(log_a).zip(iter(Both<i64>(2, 9)).map<i64>(log_b))
        var a? = c.next_back()
        var b? = c.next_back()
        var d? = c.next_back()
        var e? = c.next_back()
        expect(a? && unwrap!(a).0 == 60 && unwrap!(a).1 == 7000, "zip back one")
        expect(b? && unwrap!(b).0 == 50 && unwrap!(b).1 == 6000, "zip back two")
        expect(d? && unwrap!(d).0 == 40 && unwrap!(d).1 == 5000, "zip back three")
        expect(e? && unwrap!(e).0 == 30 && unwrap!(e).1 == 4000, "zip back four")
        expect(log_a_is([6, 5, 4, 3]), "the first side ran from the back")
        expect(log_b_is([800, 700, 600, 500, 400]), "the longer side ran once more, on the trimmed item")
    }

    // skip then nth through a zip of two mapped sources.
    clear_logs()
    {
        var v? = iter(Both<i64>(1, 7)).map<i64>(log_a).zip(iter(Both<i64>(2, 9)).map<i64>(log_b)).skip(1).nth(3)
        expect(v? && unwrap!(v).0 == 50 && unwrap!(v).1 == 6000, "zip skip nth")
        expect(log_a_is([1, 2, 3, 4, 5]), "zip skip nth ran the first side five times")
        expect(log_b_is([200, 300, 400, 500, 600]), "zip skip nth ran the second side five times")
    }

    // Forward to the end: the first side's extra item is pulled and dropped.
    clear_logs()
    {
        var c = iter(Both<i64>(1, 7)).map<i64>(log_a).zip(iter(Both<i64>(2, 5)).map<i64>(log_b))
        c.next()
        c.next()
        c.next()
        var n? = c.next()
        expect(!n?, "zip ends with the shorter side")
        expect(log_a_is([1, 2, 3, 4]), "the first side ran once more at the end")
        expect(log_b_is([200, 300, 400]), "the second side ran for its three items")
    }

    // Counters: the first side runs once more than the second when it is
    // the longer one, and the second side runs for exactly its own items.
    clear_logs()
    {
        var n = iter(Both<i64>(6)).map<i64>(bump_x).zip(iter(Both<i64>(4)).map<i64>(bump_y)).count()
        expect(n == 4, "zip of mapped sources, longer first, count")
        expect(xs_are([1, 1, 1, 1, 1, 0, 0, 0]), "longer first: the first side ran five times")
        expect(ys_are([1, 1, 1, 1, 0, 0, 0, 0]), "longer first: the second side ran for its four items")
    }

    clear_logs()
    {
        var n = iter(Both<i64>(4)).map<i64>(bump_x).zip(iter(Both<i64>(6)).map<i64>(bump_y)).count()
        expect(n == 4, "zip of mapped sources, longer second, count")
        expect(xs_are([1, 1, 1, 1, 0, 0, 0, 0]), "longer second: the first side ran for its four items")
        expect(ys_are([1, 1, 1, 1, 0, 0, 0, 0]), "longer second: the second side stopped with the first")
    }

    // From the back once: the longer side's extra items are trimmed first.
    clear_logs()
    {
        var c = iter(Both<i64>(6)).map<i64>(bump_x).zip(iter(Both<i64>(4)).map<i64>(bump_y))
        var a? = c.next_back()
        expect(a?, "zip next_back of mapped sources")
        expect(xs_are([0, 0, 0, 1, 1, 1, 0, 0]), "next_back ran the first side for its trimmed items and the pair")
        expect(ys_are([0, 0, 0, 1, 0, 0, 0, 0]), "next_back ran the second side once")
    }

    // Three from the front, then one from the back.
    clear_logs()
    {
        var c = iter(Both<i64>(6)).map<i64>(bump_x).zip(iter(Both<i64>(4)).map<i64>(bump_y))
        c.next()
        c.next()
        c.next()
        var a? = c.next_back()
        expect(a?, "zip next_back after three items")
        expect(xs_are([1, 1, 1, 1, 1, 1, 0, 0]), "every item of the first side ran")
        expect(ys_are([1, 1, 1, 1, 0, 0, 0, 0]), "every item of the second side ran")
    }

    // The side effect nested in an enumerate under a zip.
    clear_logs()
    {
        var n = iter(Both<i64>(6)).map<i64>(bump_x).enumerate().zip(iter(Both<i64>(4))).count()
        expect(n == 4, "zip of enumerate, count")
        expect(xs_are([1, 1, 1, 1, 1, 0, 0, 0]), "the first side ran five times under enumerate")
    }
}

/// The inputs of the Rust zip, enumerate and double-ended tests.
fn rust_enumerate_zip_cases() {
    var xs: [i64] = [0, 1, 2, 3, 4, 5]
    var n = 0
    var en = iter(xs.iter()).enumerate()
    loop {
        var pair? = en.next()
        if !pair? {
            break
        }

        expect(unwrap!(pair).0 as i64 == *unwrap!(pair).1, "enumerate index equals the item")
        n += 1
    }

    expect(n == 6, "enumerate visits six items")
    var c? = iter(xs.iter()).enumerate().nth(3)
    expect(c? && unwrap!(c).0 == 3 && *unwrap!(c).1 == 3, "enumerate nth(3)")
    var d? = iter(xs.iter()).enumerate().rev().nth(3)
    expect(d? && unwrap!(d).0 == 2 && *unwrap!(d).1 == 2, "enumerate nth from the back")
    expect(iter(xs.iter()).enumerate().count() == 6, "enumerate count")
    var e? = iter(xs.iter()).enumerate().skip(1).nth(1)
    expect(e? && unwrap!(e).0 == 2, "enumerate skip nth keeps the index")

    var a: [i64] = [0, 1, 2, 4, 5]
    var b: [i64] = [10, 11, 12]
    var z1? = iter(a.iter()).zip(b.iter()).nth(0)
    var z2? = iter(a.iter()).zip(b.iter()).nth(2)
    var z3? = iter(a.iter()).zip(b.iter()).nth(3)
    var z4? = iter(b.iter()).zip(a.iter()).nth(3)
    expect(z1? && *unwrap!(z1).0 == 0 && *unwrap!(z1).1 == 10, "zip nth(0)")
    expect(z2? && *unwrap!(z2).0 == 2 && *unwrap!(z2).1 == 12, "zip nth(2)")
    expect(!z3? && !z4?, "zip nth past the shorter side")

    var ws: [i64] = [1, 2, 3, 4, 5, 6]
    var ys: [i64] = [1, 2, 3, 7]
    var it = iter(ws.iter()).zip(ys.iter())
    var p1? = it.next()
    var p2? = it.next()
    var p3? = it.next_back()
    var p4? = it.next_back()
    var p5? = it.next()
    expect(p1? && *unwrap!(p1).0 == 1 && *unwrap!(p1).1 == 1, "double-ended zip first")
    expect(p2? && *unwrap!(p2).0 == 2 && *unwrap!(p2).1 == 2, "double-ended zip second")
    expect(p3? && *unwrap!(p3).0 == 4 && *unwrap!(p3).1 == 7, "double-ended zip from the back")
    expect(p4? && *unwrap!(p4).0 == 3 && *unwrap!(p4).1 == 3, "double-ended zip from the back again")
    expect(!p5?, "double-ended zip meets")
}

fn main() -> i32 {
    enumerate_front<i64>("i64")
    enumerate_front<string>("string")
    enumerate_front<Counted>("Counted")
    enumerate_back<i64>("i64")
    enumerate_back<string>("string")
    enumerate_back<Counted>("Counted")
    enumerate_after_skip<i64>("i64")
    enumerate_after_skip<Counted>("Counted")
    zip_equal<i64, i64>("i64 i64")
    zip_equal<Counted, string>("Counted string")
    zip_unequal<i64, i64>("i64 i64")
    zip_unequal<Counted, Counted>("Counted Counted")
    zip_unequal<string, Counted>("string Counted")
    zip_pulls()
    rust_zip_side_effects()
    rust_enumerate_zip_cases()
    zip_with_slices()
    move_only_pairs()
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
