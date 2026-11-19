// `rev` and `copied`: `rev` swaps the two ends, so `next` pulls from the back
// and `next_back` from the front, `rev().rev()` is the original order,
// `remaining()` is kept, and a reversed chain read from both ends alternately
// meets in the middle; `copied` turns the pointers a slice iterator yields
// into values, through every adapter that passes its items on unchanged
// (`filter`, `take`, `skip`, `take_while`, `skip_while`, `step_by`, `peekable`,
// `rev`), keeps DoubleEnded and ExactSize, and works on a generator of
// pointers. Items are integers, strings, tuples and pointers into a vector of
// move-only items read through `rev` only.
//
// Cases from Rust library/coretests/tests/iter/traits/double_ended.rs
//   (test_rev, test_iterator_rev_nth)
// Cases from Rust library/coretests/tests/iter/adapters/copied.rs
//   (test_copied)

import std::iter::*
import std::io
import self::inputs::probe::*

fn <E impl Elem> rev_cases(const label: string) {
    reset()
    {
        var c = iter(Both<E>(5)).rev()
        expect_pulls(0, 0, f"{label} rev is lazy")
        expect(c.remaining() == 5, f"{label} rev remaining")
        expect(kor(c.next()) == 4, f"{label} rev first")
        expect_pulls(0, 1, f"{label} rev pulled from the back")
        expect(kor(c.next_back()) == 0, f"{label} rev back")
        expect_pulls(1, 1, f"{label} rev back pulled from the front")
        expect(c.remaining() == 3, f"{label} rev remaining after two")
        expect(ints_are(drain_keys(move(c)), [3, 2, 1]), f"{label} rev rest")
    }

    expect_clean(f"{label} rev")

    reset()
    {
        var c = iter(Both<E>(6)).rev()
        var a = kor(c.next())
        var b = kor(c.next_back())
        var d = kor(c.next())
        var e = kor(c.next_back())
        var f = kor(c.next())
        var g = kor(c.next_back())
        expect(a == 5 && b == 0 && d == 4 && e == 1 && f == 3 && g == 2, f"{label} rev alternating")
        expect(c.remaining() == 0, f"{label} rev remaining at the end")
    }

    expect_clean(f"{label} rev alternating")

    reset()
    {
        var c = iter(Both<E>(4)).rev().rev()
        expect(c.remaining() == 4, f"{label} rev rev remaining")
        expect(ints_are(drain_keys(move(c)), [0, 1, 2, 3]), f"{label} rev rev")
        expect_pulls(5, 0, f"{label} rev rev pulls from the front")
    }

    expect_clean(f"{label} rev rev")

    reset()
    {
        var c = iter(Both<E>(0)).rev()
        expect(c.remaining() == 0 && !c.next()?, f"{label} rev of nothing")
        var d = iter(Both<E>(1)).rev()
        expect(kor(d.next_back()) == 0 && d.remaining() == 0, f"{label} rev of one")
    }

    expect_clean(f"{label} rev edges")

    reset()
    {
        var c = iter(Both<E>(5)).rev()
        var a? = c.next()
        var b? = c.next_back()
        expect(a? && b?, f"{label} rev abandoned items")
    }

    expect_clean(f"{label} rev abandoned")
}

fn rev_consumers() {
    var v: [i64] = [1, 2, 3, 4, 5]
    expect(iter(v.iter()).rev().count() == 5, "rev count")
    var l? = iter(v.iter()).rev().last()
    expect(l? && *unwrap!(l) == 1, "rev last")
    var n? = iter(v.iter()).rev().nth(1)
    expect(n? && *unwrap!(n) == 4, "rev nth")
    var f? = iter(v.iter()).rev().find(ptr_even)
    expect(f? && *unwrap!(f) == 4, "rev find")
    expect(iter(v.iter()).rev().position(ptr_even) == 1, "rev position")
    expect(iter(v.iter()).copied().rev().fold<i64>(0, shift_in) == 54321, "rev fold")
    var m? = iter(v.iter()).copied().rev().reduce(first_of)
    expect(m? && unwrap!(m) == 5, "rev reduce")
    expect(iter(v.iter()).copied().rev().map<i64>(key_of<i64>).take(2).sum() == 9, "rev map take sum")
    expect(ints_are(iter(v.iter()).copied().enumerate().rev().map<i64>(indexed<i64>).collect<[i64]>(), [4005, 3004, 2003, 1002, 1]), "rev enumerate")
    CALLS = 0
}

fn ptr_even(x: *const *const i64) -> bool = (**x & 1) == 0
fn ptr_below_5(x: *const *const i64) -> bool = **x < 5

fn shift_in(acc: i64, x: i64) -> i64 = acc * 10 + x
fn first_of(a: i64, b: i64) -> i64 = a

fn <E impl Elem> deref_of(p: *const E) -> i64 = p->key()

fn copied_cases() {
    var v: [i64] = [1, 2, 3, 4, 5, 6, 7, 8]
    var c = iter(v.iter()).copied()
    expect(c.remaining() == 8, "copied remaining")
    expect(unwrap!(c.next()) == 1 && unwrap!(c.next_back()) == 8, "copied both ends")
    expect(c.remaining() == 6, "copied remaining after two")
    expect(ints_are(c.collect<[i64]>(), [2, 3, 4, 5, 6, 7]), "copied collect")

    expect(ints_are(iter(v.iter()).filter(ptr_even).copied().collect<[i64]>(), [2, 4, 6, 8]), "filter then copied")
    expect(ints_are(iter(v.iter()).take(3).copied().collect<[i64]>(), [1, 2, 3]), "take then copied")
    expect(ints_are(iter(v.iter()).skip(6).copied().collect<[i64]>(), [7, 8]), "skip then copied")
    expect(ints_are(iter(v.iter()).take_while(ptr_below_5).copied().collect<[i64]>(), [1, 2, 3, 4]), "take_while then copied")
    expect(ints_are(iter(v.iter()).skip_while(ptr_below_5).copied().collect<[i64]>(), [5, 6, 7, 8]), "skip_while then copied")
    expect(ints_are(iter(v.iter()).step_by(3).copied().collect<[i64]>(), [1, 4, 7]), "step_by then copied")
    expect(ints_are(iter(v.iter()).peekable().copied().collect<[i64]>(), [1, 2, 3, 4, 5, 6, 7, 8]), "peekable then copied")
    expect(ints_are(iter(v.iter()).rev().copied().take(3).collect<[i64]>(), [8, 7, 6]), "rev then copied")
    expect(ints_are(iter(v.iter()).copied().rev().take(3).collect<[i64]>(), [8, 7, 6]), "copied then rev")
    expect(iter(v.iter()).copied().skip(2).take(4).remaining() == 4, "copied skip take remaining")

    var e: [i64]
    expect(iter(e.iter()).copied().count() == 0 && iter(e.iter()).copied().remaining() == 0, "copied of nothing")

    var w: [string] = ["a", "bb", "ccc"]
    var s = iter(w.iter()).copied()
    expect(s.remaining() == 3, "copied strings remaining")
    var first? = s.next()
    var last? = s.next_back()
    expect(first? && last? && unwrap!(first) == "a" && unwrap!(last) == "ccc", "copied strings both ends")
    expect(w.size() == 3 && w[0] == "a" && w[2] == "ccc", "the strings are still in the vector")
    var all = iter(w.iter()).copied().rev().collect<[string]>()
    expect(all.size() == 3 && all[0] == "ccc" && all[2] == "a", "copied strings reversed")

    var nested: [[i64]] = [[1], [2, 3], []]
    var cn = iter(nested.iter()).copied().collect<[[i64]]>()
    expect(cn.size() == 3 && cn[1].size() == 2 && cn[2].size() == 0, "copied vectors")
    expect(nested[1].size() == 2, "the original vectors are intact")
}

fn pointers_to(const v: [i64]) -> yield *const i64 {
    for p in v.iter() {
        yield p
    }
}

fn copied_generator() {
    var v: [i64] = [4, 5, 6]
    var c = iter(pointers_to(v)).copied()
    expect(unwrap!(c.next()) == 4 && unwrap!(c.next()) == 5 && unwrap!(c.next()) == 6 && !c.next()?, "copied over a generator of pointers")
    expect(iter(pointers_to(v)).copied().count() == 3, "copied generator count")
}

fn rev_over_move_only_pointers() {
    reset()
    {
        var items: [Counted]
        for var i: i64 = 0; i < 4; ++i {
            items.push(Counted(i))
        }

        var seen: i64 = 0
        var c = iter(items.iter()).rev()
        for var k: i64 = 0; k < 4; ++k {
            var p? = c.next()
            expect(p?, "move-only pointer")
            seen = seen * 10 + unwrap!(p)->get()
        }

        expect(seen == 3210 && !c.next()?, "reversed pointers to move-only items")
    }

    expect_clean("pointers to move-only items")
}

fn main() -> i32 {
    rev_cases<i64>("i64")
    rev_cases<string>("string")
    rev_cases<Counted>("Counted")
    rev_consumers()
    copied_cases()
    copied_generator()
    rev_over_move_only_pointers()
    return finish()
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
