// The consumers that return one value: `fold`, `reduce`, `count`, `last`,
// `nth`, `find`, `position`, `any`, `all` and `for_each`. Each is run on an
// empty source, on one item and on many, with integers, strings and a
// move-only class, and the number of items the source is asked for is exact:
// `fold`, `reduce`, `count`, `last` and `for_each` run to the end, `find`,
// `position`, `any`, `all` and `nth` stop at the item that decides them. The
// callbacks run once per item and not after the consumer has stopped. Items a
// consumer passes over or does not return are destroyed once.
//
// Cases from Rust library/coretests/tests/iter/traits/iterator.rs
//   (test_iterator_nth, test_iterator_last, test_all, test_any, test_find,
//   test_position, test_count, test_iterator_len)
// Cases from Rust library/coretests/tests/iter/adapters/ (the fold, count,
//   nth and last cases of each adapter file)

import std::iter::*
import std::io
import self::inputs::probe::*

fn <E impl Elem> fold_cases(const label: string) {
    reset()
    {
        expect(iter(Fwd<E>(0)).fold<i64>(7, fold_key<E>) == 7, f"{label} fold of nothing is the seed")
        expect(CALLS == 0, f"{label} fold of nothing ran nothing")
        expect(iter(Fwd<E>(1)).fold<i64>(7, fold_key<E>) == 70, f"{label} fold of one")
        expect(iter(Fwd<E>(5)).fold<i64>(1, fold_key<E>) == 101234, f"{label} fold of many")
        expect(CALLS == 6, f"{label} fold ran once per item")
        expect_pulls(1 + 2 + 6, 0, f"{label} fold pulls to the end once")
    }

    expect_clean(f"{label} fold")
    CALLS = 0

    reset()
    {
        expect(!iter(Fwd<E>(0)).reduce(keep_larger<E>)?, f"{label} reduce of nothing")
        expect(CALLS == 0, f"{label} reduce of nothing ran nothing")
        expect(kor(iter(Fwd<E>(1)).reduce(keep_larger<E>)) == 0, f"{label} reduce of one")
        expect(CALLS == 0, f"{label} reduce of one ran nothing")
        expect(kor(iter(Fwd<E>(5)).reduce(keep_larger<E>)) == 4, f"{label} reduce of many")
        expect(CALLS == 4, f"{label} reduce ran once per pair")
        expect_pulls(1 + 2 + 6, 0, f"{label} reduce pulls to the end once")
    }

    expect_clean(f"{label} reduce")
    CALLS = 0

    reset()
    {
        expect(iter(Fwd<E>(0)).count() == 0, f"{label} count of nothing")
        expect(iter(Fwd<E>(1)).count() == 1, f"{label} count of one")
        expect(iter(Fwd<E>(6)).count() == 6, f"{label} count of many")
        expect_pulls(1 + 2 + 7, 0, f"{label} count pulls to the end once")
        expect(iter(Both<E>(6)).count() == 6, f"{label} count of a sized source")
        PULLS = 0
        iter(Both<E>(4)).map<i64>(key_of<E>).count()
        expect(CALLS == 4, f"{label} count runs the callbacks of the chain")
    }

    expect_clean(f"{label} count")
    CALLS = 0

    reset()
    {
        expect(!iter(Fwd<E>(0)).last()?, f"{label} last of nothing")
        expect(kor(iter(Fwd<E>(1)).last()) == 0, f"{label} last of one")
        expect(kor(iter(Fwd<E>(6)).last()) == 5, f"{label} last of many")
        expect_pulls(1 + 2 + 7, 0, f"{label} last pulls to the end once")
    }

    expect_clean(f"{label} last")
}

fn <E impl Elem> nth_cases(const label: string) {
    reset()
    {
        expect(kor(iter(Fwd<E>(6)).nth(0)) == 0, f"{label} nth(0)")
        expect_pulls(1, 0, f"{label} nth(0) pulls one")
        expect(kor(iter(Fwd<E>(6)).nth(3)) == 3, f"{label} nth(3)")
        expect_pulls(1 + 4, 0, f"{label} nth(3) pulls four")
        expect(kor(iter(Fwd<E>(6)).nth(5)) == 5, f"{label} nth of the last")
        expect(!iter(Fwd<E>(6)).nth(6)?, f"{label} nth one past the end")
        expect(!iter(Fwd<E>(6)).nth(60)?, f"{label} nth far past the end")
        expect(!iter(Fwd<E>(0)).nth(0)?, f"{label} nth of nothing")
        expect(kor(iter(Fwd<E>(1)).nth(0)) == 0, f"{label} nth of one")
    }

    expect_clean(f"{label} nth")

    reset()
    {
        expect(kor(iter(Both<E>(8)).skip(1).nth(2)) == 3, f"{label} nth after skip")
        expect(kor(iter(Both<E>(8)).map<E>(same<E>).nth(7)) == 7, f"{label} nth through map")
        expect(kor(iter(Both<E>(8)).rev().nth(1)) == 6, f"{label} nth from the back")
        expect(kor(iter(Both<E>(8)).filter(is_odd<E>).nth(2)) == 5, f"{label} nth through filter")
    }

    expect_clean(f"{label} nth through adapters")
    CALLS = 0
}

fn <E impl Elem> search_cases(const label: string) {
    reset()
    {
        expect(kor(iter(Fwd<E>(8)).find(is_two<E>)) == 2, f"{label} find")
        expect_pulls(3, 0, f"{label} find stops at the match")
        expect(CALLS == 3, f"{label} find tested three items")
        expect(!iter(Fwd<E>(2)).find(is_two<E>)?, f"{label} find without a match")
        expect(!iter(Fwd<E>(0)).find(is_two<E>)?, f"{label} find of nothing")
        expect(kor(iter(Fwd<E>(3)).find(is_two<E>)) == 2, f"{label} find the last item")
    }

    expect_clean(f"{label} find")
    CALLS = 0

    reset()
    {
        expect((iter(Fwd<E>(8)).position(is_two<E>) ?? 99) == 2, f"{label} position")
        expect_pulls(3, 0, f"{label} position stops at the match")
        expect(!iter(Fwd<E>(2)).position(is_two<E>)?, f"{label} position without a match")
        expect(!iter(Fwd<E>(0)).position(is_two<E>)?, f"{label} position of nothing")
        expect((iter(Fwd<E>(8)).position(any_key<E>) ?? 99) == 0, f"{label} position of the first item")
    }

    expect_clean(f"{label} position")
    CALLS = 0

    reset()
    {
        expect(iter(Fwd<E>(8)).any(is_two<E>), f"{label} any")
        expect_pulls(3, 0, f"{label} any stops at the match")
        expect(!iter(Fwd<E>(2)).any(is_two<E>), f"{label} any without a match")
        expect(!iter(Fwd<E>(0)).any(is_two<E>), f"{label} any of nothing is false")
        expect(CALLS == 3 + 2, f"{label} any tests once per item")
    }

    expect_clean(f"{label} any")
    CALLS = 0

    reset()
    {
        expect(!iter(Fwd<E>(8)).all(below_3<E>), f"{label} all")
        expect_pulls(4, 0, f"{label} all stops at the first refusal")
        expect(iter(Fwd<E>(3)).all(below_3<E>), f"{label} all that holds")
        expect(iter(Fwd<E>(0)).all(is_two<E>), f"{label} all of nothing is true")
        expect(CALLS == 4 + 3, f"{label} all tests once per item")
    }

    expect_clean(f"{label} all")
    CALLS = 0
}

fn <E impl Elem> for_each_cases(const label: string) {
    reset()
    {
        SUM = 0
        iter(Fwd<E>(0)).for_each(record<E>)
        expect(SUM == 0 && CALLS == 0, f"{label} for_each of nothing")
        iter(Fwd<E>(5)).for_each(record<E>)
        expect(SUM == 10 && CALLS == 5, f"{label} for_each of many")
        expect_pulls(1 + 6, 0, f"{label} for_each pulls to the end once")
        iter(Both<E>(4)).rev().for_each(record<E>)
        expect(SUM == 16 && CALLS == 9, f"{label} for_each of a reversed source")
        SUM = 0
        iter(Both<E>(6)).filter(is_even<E>).for_each(record<E>)
        expect(SUM == 6, f"{label} for_each through filter")
    }

    expect_clean(f"{label} for_each")
    CALLS = 0
    SUM = 0
}

fn on_slices() {
    var v: [i64] = [3, 1, 4, 1, 5, 9, 2, 6]
    expect(iter(v.iter()).copied().fold<i64>(0, add) == 31, "fold over a slice")
    var r? = iter(v.iter()).copied().reduce(larger)
    expect(r? && unwrap!(r) == 9, "reduce over a slice")
    var l? = iter(v.iter()).last()
    expect(l? && *unwrap!(l) == 6, "last over a slice")
    var n? = iter(v.iter()).nth(4)
    expect(n? && *unwrap!(n) == 5, "nth over a slice")
    expect(iter(v.iter()).count() == 8, "count over a slice")
    expect(iter(v.iter()).any(ptr_is_nine), "any over a slice")
    expect(!iter(v.iter()).all(ptr_is_nine), "all over a slice")
    expect(iter(v.iter()).position(ptr_is_nine) == 5, "position over a slice")

    var w: [string] = ["x", "yy", "zzz"]
    expect(iter(w.iter()).map<usize>(len_of).fold<usize>(0, add_size) == 6, "fold over strings")
    var found? = iter(w.iter()).find(starts_with_y)
    expect(found? && *unwrap!(found) == "yy", "find over strings")
}

fn add(a: i64, b: i64) -> i64 = a + b
fn add_size(a: usize, b: usize) -> usize = a + b
fn larger(a: i64, b: i64) -> i64 = if b > a => b else => a
fn len_of(p: *const string) -> usize = p->size()
fn ptr_is_nine(p: *const *const i64) -> bool = **p == 9
fn starts_with_y(p: *const *const string) -> bool = (**p).size() > 1 && (**p)[0] == 'y'

fn main() -> i32 {
    fold_cases<i64>("i64")
    fold_cases<string>("string")
    fold_cases<Counted>("Counted")
    nth_cases<i64>("i64")
    nth_cases<string>("string")
    nth_cases<Counted>("Counted")
    search_cases<i64>("i64")
    search_cases<string>("string")
    search_cases<Counted>("Counted")
    for_each_cases<i64>("i64")
    for_each_cases<string>("string")
    for_each_cases<Counted>("Counted")
    on_slices()
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
