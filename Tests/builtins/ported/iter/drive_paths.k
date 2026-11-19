// The consumers that drive a chain through their own loop (`count`, `fold`)
// ask the source exactly as often as `next` would and never after its end:
// over double-ended chains (`rev`, `skip`, `take`, `enumerate`, `zip`), over
// forward chains (`take`, `skip`, `chain`, `take_while`, `skip_while`,
// `filter_map`, `peekable`, `step_by`, `filter`) and over `flat_map`, with
// integers, strings and a move-only class.
//
// Cases from Rust library/coretests/tests/iter/adapters/ (the count and
//   fold cases of each adapter's file, with the number of items pulled
//   observed through a counting source)

import std::iter::*
import std::io
import self::inputs::probe::*

/// The consumers drive a chain through their own loop, not through `next`:
/// the same source is asked the same number of times and never after its end.
fn <E impl Elem> consumer_paths(const label: string) {
    reset()
    {
        expect(iter(Both<E>(5)).map<i64>(key_of<E>).count() == 5, f"{label} map count")
        expect_pulls(6, 0, f"{label} map count pulls")
        PULLS = 0
        expect(iter(Both<E>(5)).rev().count() == 5, f"{label} rev count")
        expect_pulls(0, 6, f"{label} rev count pulls from the back")
        BACKS = 0
        expect(iter(Both<E>(5)).enumerate().rev().count() == 5, f"{label} enumerate rev count")
        expect_pulls(0, 6, f"{label} enumerate rev count pulls from the back")
        BACKS = 0
        expect(iter(Both<E>(5)).map<i64>(key_of<E>).rev().fold<i64>(0, shift_in) == 43210, f"{label} map rev fold")
        expect_pulls(0, 6, f"{label} map rev fold pulls from the back")
        BACKS = 0
        expect(iter(Both<E>(5)).skip(2).rev().count() == 3, f"{label} skip rev count")
        expect_pulls(0, 3, f"{label} skip rev count never reaches the skipped items")
        BACKS = 0
        expect(iter(Both<E>(6)).take(3).rev().count() == 3, f"{label} take rev count")
        expect_pulls(0, 6, f"{label} take rev count drops the items past the cut")
        BACKS = 0
        expect(iter(Both<E>(5)).zip(Both<E>(3)).count() == 3, f"{label} zip count")
        expect_pulls(8, 0, f"{label} zip count pulls each side")
        PULLS = 0
        expect(iter(Both<E>(5)).zip(Both<E>(3)).rev().count() == 3, f"{label} zip rev count")
    }

    expect_balanced(f"{label} consumers over double-ended chains")
    CALLS = 0

    reset()
    {
        expect(iter(Fwd<E>(10)).take(3).count() == 3, f"{label} take count")
        expect_pulls(3, 0, f"{label} take count pulls three")
        PULLS = 0
        expect(iter(Fwd<E>(6)).skip(2).count() == 4, f"{label} skip count")
        expect_pulls(7, 0, f"{label} skip count pulls everything and the end")
        PULLS = 0
        expect(iter(Fwd<E>(2)).chain(Fwd<E>(3)).count() == 5, f"{label} chain count")
        expect_pulls(7, 0, f"{label} chain count pulls each source to its end")
        PULLS = 0
        expect(iter(Fwd<E>(10)).take_while(below_3<E>).count() == 3, f"{label} take_while count")
        expect_pulls(4, 0, f"{label} take_while count pulls through the refused item")
        PULLS = 0
        expect(iter(Fwd<E>(6)).skip_while(below_3<E>).count() == 3, f"{label} skip_while count")
        expect_pulls(7, 0, f"{label} skip_while count pulls everything and the end")
        PULLS = 0
        expect(iter(Fwd<E>(6)).filter_map<E>(odd_only<E>).count() == 3, f"{label} filter_map count")
        expect_pulls(7, 0, f"{label} filter_map count pulls everything and the end")
        PULLS = 0
        expect(iter(Fwd<E>(3)).peekable().count() == 3, f"{label} peekable count")
        expect_pulls(4, 0, f"{label} peekable count pulls everything and the end")
        PULLS = 0
        expect(iter(Fwd<E>(5)).step_by(2).count() == 3, f"{label} step_by count")
        expect_pulls(6, 0, f"{label} step_by count pulls everything and the end")
        PULLS = 0
        expect(iter(Fwd<E>(6)).filter(is_even<E>).fold<i64>(0, fold_key<E>) == 24, f"{label} filter fold")
        expect_pulls(7, 0, f"{label} filter fold pulls everything and the end")
    }

    expect_clean(f"{label} consumers over forward chains")
    CALLS = 0

    reset()
    {
        expect(iter(Both<E>(4)).flat_map<Fwd<E>>(fwd_of<E, E>).count() == 6, f"{label} flat_map count")
        expect_pulls(5 + 10, 0, f"{label} flat_map count pulls every source to its end")
        PULLS = 0
        expect(iter(Both<E>(4)).flat_map<Fwd<E>>(fwd_of<E, E>).take(3).fold<i64>(0, fold_key<E>) == 1, f"{label} flat_map take fold")
    }

    expect_clean(f"{label} consumers over flat_map")
    CALLS = 0
}

fn shift_in(acc: i64, x: i64) -> i64 = acc * 10 + x

fn main() -> i32 {
    consumer_paths<i64>("i64")
    consumer_paths<string>("string")
    consumer_paths<Counted>("Counted")
    return finish()
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
