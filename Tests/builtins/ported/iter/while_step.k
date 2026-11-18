// `take_while`, `skip_while` and `step_by`: the items they keep, exactly how
// many items the source is asked for, that `take_while` stays ended after the
// first refusal and the source's end, that `skip_while` stops testing after
// the first item it lets through, `step_by(1)`, a step past the length, a
// step that divides the length and one that does not, the three composed with
// other adapters, and move-only items (the item that is refused is dropped
// once). None of the three is DoubleEnded or ExactSize here: capabilities.k.
// `step_by(0)` traps: traps.k.
//
// Cases from Rust library/coretests/tests/iter/adapters/take_while.rs
//   (test_iterator_take_while)
// Cases from Rust library/coretests/tests/iter/adapters/skip_while.rs
//   (test_iterator_skip_while)
// Cases from Rust library/coretests/tests/iter/adapters/step_by.rs
//   (test_iterator_step_by, test_iterator_step_by_nth, test_step_by_skip)

import std::iter::*
import std::io
import self::inputs::probe::*

fn <E impl Elem> take_while_cases(const label: string) {
    reset()
    {
        var c = iter(Fwd<E>(10)).take_while(below_3<E>)
        expect_pulls(0, 0, f"{label} take_while is lazy")
        expect(CALLS == 0, f"{label} take_while tested nothing")
        expect(kor(c.next()) == 0, f"{label} take_while first")
        expect(CALLS == 1, f"{label} take_while tested once")
        expect(ints_are(drain_keys(move(c)), [1, 2]), f"{label} take_while rest")
        expect_pulls(4, 0, f"{label} take_while pulls through the refused item")
        expect(CALLS == 4, f"{label} take_while tests each pulled item once")
    }

    expect_clean(f"{label} take_while")
    CALLS = 0

    reset()
    {
        var c = iter(Fwd<E>(10)).take_while(below_3<E>)
        while kor(c.next()) >= 0 { }

        expect_pulls(4, 0, f"{label} take_while drained")
        expect(!c.next()? && !c.next()?, f"{label} take_while stays ended")
        expect_pulls(4, 0, f"{label} take_while is not pulled after its end")
    }

    expect_clean(f"{label} take_while ended")
    CALLS = 0

    reset()
    {
        var c = iter(Fwd<E>(2)).take_while(below_3<E>)
        expect(ints_are(drain_keys(move(c)), [0, 1]), f"{label} take_while of a short source")
        expect_pulls(3, 0, f"{label} take_while stops at the source's end")
        expect(!iter(Fwd<E>(0)).take_while(below_3<E>).next()?, f"{label} take_while of nothing")
        expect(iter(Fwd<E>(5)).take_while(below_5<E>).count() == 5, f"{label} take_while keeps all")
    }

    expect_clean(f"{label} take_while edges")
    CALLS = 0

    reset()
    {
        var c = iter(Fwd<E>(10)).take_while(is_odd<E>)
        expect(!c.next()?, f"{label} take_while refuses the first item")
        expect_pulls(1, 0, f"{label} take_while pulled only the first")
    }

    expect_clean(f"{label} take_while refuses at once")
    CALLS = 0
}

fn <E impl Elem> skip_while_cases(const label: string) {
    reset()
    {
        var c = iter(Fwd<E>(8)).skip_while(below_3<E>)
        expect_pulls(0, 0, f"{label} skip_while is lazy")
        expect(kor(c.next()) == 3, f"{label} skip_while first")
        expect_pulls(4, 0, f"{label} skip_while pulled the skipped items and one")
        expect(CALLS == 4, f"{label} skip_while tested four")
        expect(ints_are(drain_keys(move(c)), [4, 5, 6, 7]), f"{label} skip_while rest")
        expect(CALLS == 4, f"{label} skip_while stops testing after the first pass")
        expect_pulls(9, 0, f"{label} skip_while pulls each item once")
    }

    expect_clean(f"{label} skip_while")
    CALLS = 0

    reset()
    {
        var c = iter(Fwd<E>(6)).skip_while(is_odd<E>)
        expect(ints_are(drain_keys(move(c)), [0, 1, 2, 3, 4, 5]), f"{label} skip_while that skips nothing")
        expect(CALLS == 1, f"{label} skip_while tested only the first")
    }

    expect_clean(f"{label} skip_while skips nothing")
    CALLS = 0

    reset()
    {
        var c = iter(Fwd<E>(3)).skip_while(below_5<E>)
        expect(!c.next()?, f"{label} skip_while skips everything")
        expect_pulls(4, 0, f"{label} skip_while pulled to the end")
        expect(!iter(Fwd<E>(0)).skip_while(below_5<E>).next()?, f"{label} skip_while of nothing")
    }

    expect_clean(f"{label} skip_while skips all")
    CALLS = 0

    reset()
    {
        // The predicate holds again later: only the leading run is skipped.
        var c = iter(Fwd<E>(7)).skip_while(below_3<E>).filter(below_5<E>)
        expect(ints_are(drain_keys(move(c)), [3, 4]), f"{label} skip_while then filter")
    }

    expect_clean(f"{label} skip_while then filter")
    CALLS = 0
}

fn <E impl Elem> step_by_cases(const label: string) {
    reset()
    {
        var c = iter(Fwd<E>(7)).step_by(3)
        expect_pulls(0, 0, f"{label} step_by is lazy")
        expect(kor(c.next()) == 0, f"{label} step_by first")
        expect_pulls(1, 0, f"{label} the first item is pulled alone")
        expect(kor(c.next()) == 3, f"{label} step_by second")
        expect_pulls(4, 0, f"{label} step_by skipped two")
        expect(kor(c.next()) == 6, f"{label} step_by third")
        expect(kor(c.next()) == -1, f"{label} step_by ends")
        expect_pulls(8, 0, f"{label} step_by pulls each item once")
    }

    expect_clean(f"{label} step_by")

    reset()
    {
        expect(ints_are(drain_keys(iter(Fwd<E>(6)).step_by(1)), [0, 1, 2, 3, 4, 5]), f"{label} step_by(1)")
        expect_pulls(7, 0, f"{label} step_by(1) pulls each once")
    }

    expect_clean(f"{label} step_by(1)")

    reset()
    {
        expect(ints_are(drain_keys(iter(Fwd<E>(6)).step_by(2)), [0, 2, 4]), f"{label} step_by(2) over an even length")
        expect(ints_are(drain_keys(iter(Fwd<E>(7)).step_by(2)), [0, 2, 4, 6]), f"{label} step_by(2) over an odd length")
        expect(ints_are(drain_keys(iter(Fwd<E>(6)).step_by(6)), [0]), f"{label} step equal to the length")
        expect(ints_are(drain_keys(iter(Fwd<E>(6)).step_by(100)), [0]), f"{label} step past the length")
        expect(ints_are(drain_keys(iter(Fwd<E>(6)).step_by(usize::MAX)), [0]), f"{label} the largest step")
        expect(drain_keys(iter(Fwd<E>(0)).step_by(3)).size() == 0, f"{label} step_by of nothing")
        expect(ints_are(drain_keys(iter(Fwd<E>(1)).step_by(3)), [0]), f"{label} step_by of one")
    }

    expect_clean(f"{label} step_by sizes")

    reset()
    {
        var c = iter(Fwd<E>(10)).step_by(4)
        var a? = c.next()
        expect(a?, f"{label} step_by abandoned item")
    }

    expect_clean(f"{label} step_by abandoned")
}

/// The inputs of the Rust take_while, skip_while and step_by tests.
fn rust_while_step_cases() {
    var xs: [i64] = [0, 1, 2, 3, 5, 13, 15, 16, 17, 19]
    var below_15 = iter(xs.iter()).take_while(ptr_below_15).map<i64>(deref_i64).collect<[i64]>()
    expect(ints_are(below_15, [0, 1, 2, 3, 5, 13]), "take_while below 15")
    var from_15 = iter(xs.iter()).skip_while(ptr_below_15).map<i64>(deref_i64).collect<[i64]>()
    expect(ints_are(from_15, [15, 16, 17, 19]), "skip_while below 15")
    expect(iter(xs.iter()).skip_while(ptr_below_15).map<i64>(deref_i64).fold<i64>(0, add) == 67, "skip_while fold")

    // A skip_while that already passed its first item folds the rest.
    var c = iter(xs.iter()).skip_while(ptr_below_15)
    var first? = c.next()
    expect(first? && *unwrap!(first) == 15, "skip_while processes the skips before the first item")
    expect(c.map<i64>(deref_i64).fold<i64>(0, add) == 52, "fold after the first item of skip_while")

    // Identity and step 3 over a long source, cut by take.
    var a = drain_keys(iter(Both<i64>(100)).step_by(1).take(3))
    var b = drain_keys(iter(Both<i64>(100)).step_by(3).take(4))
    expect(ints_are(a, [0, 1, 2]) && ints_are(b, [0, 3, 6, 9]), "step_by over a long source")

    // nth through step_by: the position counts in steps.
    for var k: usize = 0; k < 5; ++k {
        var n? = iter(Both<i64>(16)).step_by(5).nth(k)
        var m? = iter(Both<i64>(18)).step_by(5).nth(k)
        if k < 4 {
            expect(n? && unwrap!(n) == (k as i64) * 5, "step_by(5) of 16, nth")
            expect(m? && unwrap!(m) == (k as i64) * 5, "step_by(5) of 18, nth")
        } else {
            expect(!n? && !m?, "step_by(5) nth past the end")
        }
    }

    expect(!iter(Both<i64>(18)).step_by(5).nth(42)?, "step_by nth far past the end")
    var sk = drain_keys(iter(Both<i64>(20)).step_by(3).skip(1).step_by(2))
    expect(ints_are(sk, [3, 9, 15]), "step_by skip step_by")
}

fn ptr_below_15(p: *const *const i64) -> bool = **p < 15
fn deref_i64(p: *const i64) -> i64 = *p
fn add(a: i64, b: i64) -> i64 = a + b

fn composed() {
    var v: [i64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    expect(ints_are(iter(v.iter()).copied().step_by(3).collect<[i64]>(), [0, 3, 6, 9]), "step_by of a slice")
    expect(ints_are(iter(v.iter()).copied().skip(1).step_by(3).collect<[i64]>(), [1, 4, 7]), "skip then step_by")
    expect(ints_are(iter(v.iter()).copied().step_by(3).skip(1).collect<[i64]>(), [3, 6, 9]), "step_by then skip")
    expect(ints_are(iter(v.iter()).copied().step_by(2).step_by(2).collect<[i64]>(), [0, 4, 8]), "step_by twice")
    expect(ints_are(iter(v.iter()).copied().take_while(below_5<i64>).step_by(2).collect<[i64]>(), [0, 2, 4]), "take_while then step_by")
    expect(ints_are(iter(v.iter()).copied().skip_while(below_3<i64>).take_while(below_5<i64>).collect<[i64]>(), [3, 4]), "skip_while then take_while")
    expect(ints_are(iter(v.iter()).copied().step_by(2).enumerate().map<i64>(indexed<i64>).collect<[i64]>(), [0, 1002, 2004, 3006, 4008]), "step_by then enumerate")
    expect(ints_are(iter(v.iter()).copied().map<i64>(key_plus_100<i64>).step_by(4).collect<[i64]>(), [100, 104, 108]), "map then step_by")
    expect(iter(v.iter()).copied().step_by(3).count() == 4, "step_by count")
    var n? = iter(v.iter()).copied().step_by(3).nth(2)
    expect(n? && unwrap!(n) == 6, "step_by nth")
    var l? = iter(v.iter()).copied().step_by(4).last()
    expect(l? && unwrap!(l) == 8, "step_by last")
    CALLS = 0
}

fn move_only() {
    reset()
    {
        var a = iter(Fwd<Counted>(10)).step_by(3).collect<[Counted]>()
        expect(keys_are(a, [0, 3, 6, 9]), "step_by move-only items")
    }

    expect_clean("step_by move-only")

    reset()
    {
        var a = iter(Fwd<Counted>(10)).take_while(below_5<Counted>).collect<[Counted]>()
        expect(keys_are(a, [0, 1, 2, 3, 4]), "take_while move-only items")
    }

    expect_clean("take_while move-only")

    reset()
    {
        var a = iter(Fwd<Counted>(10)).skip_while(below_5<Counted>).collect<[Counted]>()
        expect(keys_are(a, [5, 6, 7, 8, 9]), "skip_while move-only items")
    }

    expect_clean("skip_while move-only")
    CALLS = 0
}

fn main() -> i32 {
    take_while_cases<i64>("i64")
    take_while_cases<string>("string")
    take_while_cases<Counted>("Counted")
    skip_while_cases<i64>("i64")
    skip_while_cases<string>("string")
    skip_while_cases<Counted>("Counted")
    step_by_cases<i64>("i64")
    step_by_cases<string>("string")
    step_by_cases<Counted>("Counted")
    rust_while_step_cases()
    composed()
    move_only()
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
