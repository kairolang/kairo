// The sources of a chain and what `iter()` gives over them: a vector, a
// slice, an empty vector, a generator, and a user iterator that is
// `Iterator`, `DoubleEnded` and `ExactSize`. Each is read to its end from the
// front, from the back and from both ends alternately; `remaining()` is exact
// before and after partial consumption, and a source is never asked again
// after it returned null. Items are integers, strings and a move-only class
// that counts its constructions, moves and destructions.
//
// Cases from Rust library/coretests/tests/iter/traits/double_ended.rs
//   (test_rev, test_iterator_rev_nth) and traits/iterator.rs
//   (test_iterator_last, test_iterator_len: the plain-source cases)
// Cases from Rust library/coretests/tests/iter/range.rs
//   (reading a sequence from both ends until the ends meet)

import std::iter::*
import std::io
import self::inputs::probe::*

fn gen(n: i64) -> yield i64 {
    for var i: i64 = 0; i < n; i += 1 {
        yield i * 10
    }
}

fn gen_strings(n: i64) -> yield string {
    for var i: i64 = 0; i < n; i += 1 {
        yield f"g{i}"
    }
}

fn gen_counted(n: i64) -> yield Counted {
    for var i: i64 = 0; i < n; i += 1 {
        yield Counted(i)
    }
}

fn slice_of_vector() {
    var v: [i64] = [1, 2, 3, 4, 5]
    var s: [const i64;] = v
    expect(iter(s.iter()).copied().count() == 5, "slice count")
    expect(iter(v.iter()).copied().count() == 5, "vector count")
    expect(ints_are(iter(v.iter()).copied().collect<[i64]>(), [1, 2, 3, 4, 5]), "vector collect")
    expect(ints_are(iter(s.iter()).rev().copied().collect<[i64]>(), [5, 4, 3, 2, 1]), "slice reversed")
    expect(iter(v.iter()).remaining() == 5, "vector remaining")

    var sub: [const i64;] = v[1..4]
    expect(ints_are(iter(sub.iter()).copied().collect<[i64]>(), [2, 3, 4]), "sub-slice collect")
    expect(iter(sub.iter()).remaining() == 3, "sub-slice remaining")
}

fn empty_and_one() {
    var e: [i64]
    expect(iter(e.iter()).count() == 0, "empty count")
    expect(iter(e.iter()).remaining() == 0, "empty remaining")
    var a = iter(e.iter())
    expect(!a.next()? && !a.next_back()?, "empty both ends")
    expect(iter(e.iter()).copied().collect<[i64]>().size() == 0, "empty collect")
    expect(!iter(e.iter()).last()?, "empty last")
    expect(!iter(e.iter()).rev().next()?, "empty reversed")

    var one: [i64] = [7]
    var b = iter(one.iter())
    expect(b.remaining() == 1, "one remaining")
    var x? = b.next_back()
    expect(x? && *unwrap!(x) == 7 && b.remaining() == 0, "one from the back")
    expect(!b.next()? && !b.next_back()?, "one then nothing")

    var c = iter(one.iter())
    var y? = c.next()
    expect(y? && *unwrap!(y) == 7 && !c.next_back()?, "one from the front")
}

fn both_ends_alternately() {
    var v: [i64] = [0, 1, 2, 3, 4, 5, 6]
    var it = iter(v.iter())
    var got: [i64]
    var left = it.remaining()
    var from_front = true
    loop {
        var x? = if from_front => it.next() else => it.next_back()
        if !x? {
            break
        }

        got.push(*unwrap!(x))
        left -= 1
        expect(it.remaining() == left, "remaining while alternating")
        from_front = !from_front
    }

    expect(ints_are(got, [0, 6, 1, 5, 2, 4, 3]), "alternating order")
    expect(it.remaining() == 0, "alternating end")

    var w: [i64] = [0, 1, 2, 3]
    var it2 = iter(w.iter())
    var a? = it2.next_back()
    var b? = it2.next_back()
    var c? = it2.next()
    var d? = it2.next_back()
    var e? = it2.next()
    expect(a? && b? && c? && d? && !e?, "even length meets in the middle")
    expect(*unwrap!(a) == 3 && *unwrap!(b) == 2 && *unwrap!(c) == 0 && *unwrap!(d) == 1, "even length values")
}

fn remaining_through_consumption() {
    var v: [string] = ["a", "b", "c", "d", "e", "f"]
    var it = iter(v.iter())
    expect(it.remaining() == 6, "string remaining 6")
    var x? = it.next()
    expect(it.remaining() == 5, "string remaining 5")
    var y? = it.next_back()
    expect(it.remaining() == 4, "string remaining 4")
    var n = 0
    while it.next()? {
        n += 1
        expect(it.remaining() == (4 - n) as usize, "string remaining counting down")
    }

    expect(n == 4 && x? && y? && *unwrap!(x) == "a" && *unwrap!(y) == "f", "string ends")
}

fn generator_source() {
    expect(ints_are(iter(gen(4)).collect<[i64]>(), [0, 10, 20, 30]), "generator collect")
    expect(iter(gen(0)).count() == 0, "empty generator")
    expect(iter(gen(1)).count() == 1, "one-item generator")
    var g = iter(gen(3))
    expect((g.next() ?? -1) == 0 && (g.next() ?? -1) == 10 && (g.next() ?? -1) == 20, "generator in order")
    expect(!g.next()?, "generator ends")
    var s = iter(gen_strings(3)).collect<[string]>()
    expect(s.size() == 3 && s[0] == "g0" && s[2] == "g2", "generator of strings")

    reset()
    {
        var c = iter(gen_counted(4)).collect<[Counted]>()
        expect(keys_are(c, [0, 1, 2, 3]), "generator of move-only items")
    }

    expect_clean("generator of move-only items")
    reset()
    {
        var c = iter(gen_counted(4))
        var first? = c.next()
        expect(first?, "generator abandoned after one item")
    }

    expect_clean("generator abandoned")
}

fn <E impl Elem> user_source_both_ends(const label: string) {
    reset()
    {
        var it = iter(Both<E>(5))
        expect(it.remaining() == 5, f"{label} remaining")
        expect_pulls(0, 0, f"{label} built")
        var a? = it.next()
        var b? = it.next_back()
        var c? = it.next()
        expect(a? && b? && c?, f"{label} three items")
        expect(unwrap!(a).key() == 0 && unwrap!(b).key() == 4 && unwrap!(c).key() == 1, f"{label} values")
        expect(it.remaining() == 2, f"{label} remaining after three")
        expect_pulls(2, 1, f"{label} pulls")
        var d? = it.next_back()
        var e? = it.next()
        var f? = it.next_back()
        expect(d? && e? && !f?, f"{label} meet")
        expect(it.remaining() == 0, f"{label} remaining at the end")
        expect_pulls(3, 3, f"{label} pulls at the end")
        expect_trace([0, 1004, 1, 1003, 2], f"{label} order")
    }

    expect_clean(f"{label} both ends")

    reset()
    {
        var empty = iter(Both<E>(0))
        expect(empty.remaining() == 0 && !empty.next()?, f"{label} empty")
    }

    expect_clean(f"{label} empty")

    reset()
    {
        var v = drain_keys(iter(Both<E>(6)).rev())
        expect(ints_are(v, [5, 4, 3, 2, 1, 0]), f"{label} reversed")
        expect_pulls(0, 7, f"{label} reversed pulls")
    }

    expect_clean(f"{label} reversed")

    reset()
    {
        var v = drain_keys(iter(Both<E>(3, 7)))
        expect(ints_are(v, [3, 4, 5, 6]), f"{label} offset range")
        expect_pulls(5, 0, f"{label} offset pulls")
    }

    expect_clean(f"{label} offset range")
}

fn abandoned_half_way() {
    reset()
    {
        var it = iter(Both<Counted>(6))
        var a? = it.next()
        var b? = it.next_back()
        expect(a? && b?, "abandon items")
    }

    expect_clean("source abandoned with items in hand")
    reset()
    {
        var it = iter(Fwd<Counted>(6))
        var a? = it.next()
        expect(a?, "forward item")
    }

    expect_clean("forward source abandoned")
}

fn add_ten(p: *i64) {
    *p += 10
}

fn bumped(p: *i64) -> i64 {
    *p += 1
    return *p
}

/// `iter_mut()` is DoubleEnded and ExactSize too, and writes through its
/// items.
fn slice_iter_mut() {
    var v: [i64] = [1, 2, 3, 4, 5]
    var it = iter(v.iter_mut())
    expect(it.remaining() == 5, "iter_mut remaining")
    var a? = it.next()
    var z? = it.next_back()
    expect(a? && z?, "iter_mut both ends")
    *unwrap!(a) = 100
    *unwrap!(z) = 500
    expect(it.remaining() == 3, "iter_mut remaining after two")
    it.for_each(add_ten)
    expect(ints_are(v, [100, 12, 13, 14, 500]), "iter_mut writes through the pointers")

    var w: [i64] = [1, 2, 3, 4, 5, 6]
    iter(w.iter_mut()).skip(1).take(3).for_each(add_ten)
    expect(ints_are(w, [1, 12, 13, 14, 5, 6]), "iter_mut skip take for_each")
    iter(w.iter_mut()).rev().take(2).for_each(add_ten)
    expect(ints_are(w, [1, 12, 13, 14, 15, 16]), "iter_mut rev take for_each")
    var sum = iter(w.iter_mut()).map<i64>(bumped).sum()
    expect(sum == 1 + 12 + 13 + 14 + 15 + 16 + 6, "iter_mut map writes and reads")
    expect(ints_are(w, [2, 13, 14, 15, 16, 17]), "iter_mut map wrote every item")
    var e: [i64]
    var ev = iter(e.iter_mut())
    expect(ev.remaining() == 0 && !ev.next()? && !ev.next_back()?, "iter_mut of nothing")

    var s: [string] = ["a", "b", "c"]
    var last? = iter(s.iter_mut()).rev().next()
    expect(last?, "iter_mut over strings")
    unwrap!(last)->push_str("!")
    expect(s[2] == "c!" && s[0] == "a", "iter_mut writes a string")
}

fn main() -> i32 {
    slice_of_vector()
    empty_and_one()
    both_ends_alternately()
    remaining_through_consumption()
    generator_source()
    user_source_both_ends<i64>("i64")
    user_source_both_ends<string>("string")
    user_source_both_ends<Counted>("Counted")
    abandoned_half_way()
    slice_iter_mut()
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
