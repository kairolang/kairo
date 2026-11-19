// `chain`: the items of the first source then the second, empty halves,
// laziness (the second source is not touched until the first has ended, the
// first is released when it ends and never asked again), reading from the
// back (the second source is drained first) and from both ends alternately,
// a chain of slice iterators, three sources deep, and move-only items.
// A chain is not ExactSize: capabilities.k.
//
// Documented behaviour that differs from the Rust adapter: from the back the
// chain does not remember that the second source has ended, so each further
// `next_back` asks it again (Lib/std/iter.k, the `DoubleEnded` extension of
// `Chain`). The cases that drain a chain from the back therefore check the
// items and the balance of what is alive, not that a source is never asked
// after its end; the others check both.
//
// Cases from Rust library/coretests/tests/iter/adapters/chain.rs
//   (test_iterator_chain, test_iterator_chain_nth, test_iterator_chain_last,
//   test_iterator_chain_count, test_iterator_chain_find, test_chain_fold,
//   test_double_ended_chain)

import std::iter::*
import std::io
import self::inputs::probe::*

fn <E impl Elem> chain_front(const label: string) {
    reset()
    {
        var c = iter(Fwd<E>(2)).chain(Fwd<E>(3))
        expect_pulls(0, 0, f"{label} chain is lazy")
        expect(SOURCES == 2, f"{label} chain holds both sources")
        expect(kor(c.next()) == 0, f"{label} first item")
        expect(kor(c.next()) == 1, f"{label} second item")
        expect_pulls(2, 0, f"{label} the second source is untouched")
        expect(SOURCES == 2, f"{label} the first source is alive until its end is seen")
        expect(kor(c.next()) == 0, f"{label} first item of the second")
        expect_pulls(2 + 1 + 1, 0, f"{label} the first source was asked for its end once")
        expect(SOURCES == 1, f"{label} the first source is released when it ends")
        expect(ints_are(drain_keys(move(c)), [1, 2]), f"{label} rest of the second")
    }

    expect_clean(f"{label} chain")

    reset()
    {
        var c = iter(Fwd<E>(2)).chain(Fwd<E>(3))
        expect(drain_keys(move(c)).size() == 5, f"{label} chain count")
        expect_pulls(3 + 4, 0, f"{label} chain pulls each source to its end once")
    }

    expect_clean(f"{label} chain drained")

    reset()
    {
        expect(drain_keys(iter(Fwd<E>(0)).chain(Fwd<E>(3))).size() == 3, f"{label} empty first half")
        expect(drain_keys(iter(Fwd<E>(3)).chain(Fwd<E>(0))).size() == 3, f"{label} empty second half")
        expect(drain_keys(iter(Fwd<E>(0)).chain(Fwd<E>(0))).size() == 0, f"{label} both halves empty")
    }

    expect_clean(f"{label} chain empty halves")
}

fn <E impl Elem> chain_back(const label: string) {
    reset()
    {
        var c = iter(Both<E>(2)).chain(Both<E>(3))
        var a = kor(c.next_back())
        var b = kor(c.next_back())
        var d = kor(c.next_back())
        expect(a == 2 && b == 1 && d == 0, f"{label} second half from the back")
        expect_pulls(0, 3, f"{label} the first half is untouched")
        expect(SOURCES == 2, f"{label} nothing released from the back yet")
        var e = kor(c.next_back())
        var f = kor(c.next_back())
        expect(e == 1 && f == 0, f"{label} first half from the back")
    }

    expect_balanced(f"{label} chain from the back")

    reset()
    {
        var c = iter(Both<E>(2)).chain(Both<E>(3))
        var a = kor(c.next())
        var b = kor(c.next_back())
        var d = kor(c.next())
        var e = kor(c.next_back())
        var f = kor(c.next())
        expect(a == 0 && b == 2 && d == 1 && e == 1 && f == 0, f"{label} chain alternating")
    }

    expect_clean(f"{label} chain alternating")

    reset()
    {
        var c = iter(Both<E>(2)).chain(Both<E>(3)).rev()
        expect(ints_are(drain_keys(move(c)), [2, 1, 0, 1, 0]), f"{label} chain reversed")
    }

    expect_balanced(f"{label} chain reversed")

    reset()
    {
        expect(!iter(Both<E>(0)).chain(Both<E>(0)).next_back()?, f"{label} empty chain from the back")
        expect(kor(iter(Both<E>(2)).chain(Both<E>(0)).next_back()) == 1, f"{label} empty second half from the back")
    }

    expect_clean(f"{label} chain empty from the back")
}

fn deref_i64(p: *const i64) -> i64 = *p

fn chain_of_slices() {
    var a: [i64] = [1, 2, 3]
    var b: [i64] = [4, 5]
    var c: [i64] = [6]
    var e: [i64]
    expect(ints_are(iter(a.iter()).chain(b.iter()).map<i64>(deref_i64).collect<[i64]>(), [1, 2, 3, 4, 5]), "two slices chained")
    expect(ints_are(iter(a.iter()).chain(b.iter()).chain(c.iter()).map<i64>(deref_i64).collect<[i64]>(), [1, 2, 3, 4, 5, 6]), "three slices chained")
    expect(ints_are(iter(a.iter()).chain(b.iter()).chain(c.iter()).rev().map<i64>(deref_i64).collect<[i64]>(), [6, 5, 4, 3, 2, 1]), "three slices from the back")
    expect(ints_are(iter(e.iter()).chain(a.iter()).chain(e.iter()).map<i64>(deref_i64).collect<[i64]>(), [1, 2, 3]), "empty slices at the ends")
    expect(iter(e.iter()).chain(e.iter()).count() == 0, "two empty slices")

    var x = iter(a.iter()).chain(b.iter())
    var first? = x.next()
    var last? = x.next_back()
    expect(first? && last? && *unwrap!(first) == 1 && *unwrap!(last) == 5, "chained slices, both ends")
    expect(iter(a.iter()).chain(b.iter()).count() == 5, "chained slices count")
    var n? = iter(a.iter()).chain(b.iter()).nth(3)
    expect(n? && *unwrap!(n) == 4, "chained slices nth")
}

/// The inputs of the Rust chain tests, over slice iterators.
fn rust_chain_cases() {
    var xs: [i64] = [0, 1, 2, 3, 4, 5]
    var ys: [i64] = [30, 40, 50, 60]
    var zs: [i64]
    var expected: [i64] = [0, 1, 2, 3, 4, 5, 30, 40, 50, 60]
    expect(ints_are(iter(xs.iter()).chain(ys.iter()).map<i64>(deref_i64).collect<[i64]>(), expected), "chain of two slices, in order")
    for var i: usize = 0; i < expected.size(); ++i {
        var x? = iter(xs.iter()).chain(ys.iter()).nth(i)
        expect(x? && *unwrap!(x) == expected[i], "chain nth through both halves")
    }

    var z? = iter(zs.iter()).chain(xs.iter()).nth(0)
    expect(z? && *unwrap!(z) == 0, "chain nth(0) with an empty first half")
    var f? = iter(xs.iter()).chain(zs.iter()).nth(5)
    expect(f? && *unwrap!(f) == 5, "chain nth(5) with an empty second half")
    expect(!iter(xs.iter()).chain(ys.iter()).nth(10)?, "chain nth one past the end")

    var l1? = iter(xs.iter()).chain(ys.iter()).last()
    var l2? = iter(zs.iter()).chain(ys.iter()).last()
    var l3? = iter(ys.iter()).chain(zs.iter()).last()
    expect(l1? && *unwrap!(l1) == 60 && l2? && *unwrap!(l2) == 60 && l3? && *unwrap!(l3) == 60, "chain last")
    expect(!iter(zs.iter()).chain(zs.iter()).last()?, "chain last of nothing")
    expect(iter(xs.iter()).chain(ys.iter()).count() == 10 && iter(zs.iter()).chain(ys.iter()).count() == 4, "chain count")

    var f1? = iter(xs.iter()).chain(ys.iter()).find(ptr_is_4)
    var f2? = iter(xs.iter()).chain(ys.iter()).find(ptr_is_40)
    expect(f1? && *unwrap!(f1) == 4 && f2? && *unwrap!(f2) == 40, "chain find in either half")
    expect(!iter(xs.iter()).chain(ys.iter()).find(ptr_is_100)?, "chain find without a match")

    // The items after a partial read are folded.
    var c = iter(xs.iter()).chain(ys.iter())
    c.next()
    var folded = c.map<i64>(deref_i64).fold<i64>(0, shift_digit)
    expect(folded == 195, "chain fold after one item")
    var d = iter(xs.iter()).chain(ys.iter())
    d.next()
    expect(d.map<i64>(deref_i64).sum() == 195, "chain sum after one item")

    // From both ends through rev.
    var a: [i64] = [1, 2, 3, 4, 5]
    var b: [i64] = [7, 9, 11]
    var r = iter(a.iter()).chain(b.iter()).rev()
    var want_front: [i64] = [11, 9]
    var want_back: [i64] = [1, 2, 3, 4, 5, 7]
    for var i: usize = 0; i < want_front.size(); ++i {
        var x? = r.next()
        expect(x? && *unwrap!(x) == want_front[i], "chain rev from the front")
    }

    for var i: usize = 0; i < want_back.size(); ++i {
        var x? = r.next_back()
        expect(x? && *unwrap!(x) == want_back[i], "chain rev from the back")
    }

    expect(!r.next_back()?, "chain rev meets")
}

fn ptr_is_4(p: *const *const i64) -> bool = **p == 4
fn ptr_is_40(p: *const *const i64) -> bool = **p == 40
fn ptr_is_100(p: *const *const i64) -> bool = **p == 100
fn shift_digit(acc: i64, x: i64) -> i64 = acc + x

fn chain_three_deep() {
    reset()
    {
        var c = iter(Fwd<i64>(2)).chain(Fwd<i64>(2)).chain(Fwd<i64>(2))
        expect(ints_are(drain_keys(move(c)), [0, 1, 0, 1, 0, 1]), "three sources deep")
        expect_pulls(3 + 3 + 3, 0, "three sources deep pulls")
    }

    expect_clean("three sources deep")

    reset()
    {
        var c = iter(Fwd<i64>(2)).chain(Fwd<i64>(2)).chain(Fwd<i64>(2)).take(3)
        expect(ints_are(drain_keys(move(c)), [0, 1, 0]), "chain then take")
        expect_pulls(3 + 1, 0, "chain then take pulls")
    }

    expect_clean("chain then take")
}

fn chain_move_only() {
    reset()
    {
        var v = iter(Fwd<Counted>(3)).chain(Fwd<Counted>(2)).collect<[Counted]>()
        expect(keys_are(v, [0, 1, 2, 0, 1]), "chained move-only items")
    }

    expect_clean("chained move-only items")

    reset()
    {
        var c = iter(Both<Counted>(3)).chain(Both<Counted>(3))
        var a? = c.next()
        var b? = c.next_back()
        expect(a? && b?, "chained abandoned items")
    }

    expect_balanced("chain abandoned with both ends in hand")

    reset()
    {
        var c = iter(Fwd<Counted>(1)).chain(Fwd<Counted>(3))
        var a? = c.next()
        var b? = c.next()
        expect(a? && b?, "chain abandoned in the second half")
        expect(SOURCES == 1, "only the second half is alive")
    }

    expect_clean("chain abandoned in the second half")
}

fn main() -> i32 {
    chain_front<i64>("i64")
    chain_front<string>("string")
    chain_front<Counted>("Counted")
    chain_back<i64>("i64")
    chain_back<string>("string")
    chain_back<Counted>("Counted")
    chain_of_slices()
    rust_chain_cases()
    chain_three_deep()
    chain_move_only()
    return finish()
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
