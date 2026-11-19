// `take` and `skip`: the items they keep, `take(0)`, `take(n)` past the end,
// `skip(0)`, `skip(n)` past the end, exactly how many items the source is
// asked for (the item after the last one taken is never pulled; the skipped
// items are pulled and dropped on the first `next`), `remaining()` before and
// after partial consumption, reading from the back (`take` drops what lies
// past the cut first, `skip` never reaches the skipped items), alternating
// ends, the two composed in both orders, and move-only items.
//
// Cases from Rust library/coretests/tests/iter/adapters/take.rs
//   (test_iterator_take, test_iterator_take_nth, test_iterator_take_nth_back,
//   test_iterator_take_short, test_reverse_on_zip)
// Cases from Rust library/coretests/tests/iter/adapters/skip.rs
//   (test_iterator_skip, test_iterator_skip_doubleended,
//   test_iterator_skip_nth, test_iterator_skip_count, test_iterator_skip_last,
//   test_skip_nth_back)

import std::iter::*
import std::io
import self::inputs::probe::*

fn <E impl Elem> take_front(const label: string) {
    reset()
    {
        var c = iter(Both<E>(10)).take(3)
        expect_pulls(0, 0, f"{label} take is lazy")
        expect(c.remaining() == 3, f"{label} take remaining")
        expect(kor(c.next()) == 0, f"{label} take first")
        expect(c.remaining() == 2, f"{label} take remaining after one")
        expect(ints_are(drain_keys(move(c)), [1, 2]), f"{label} take rest")
        expect_pulls(3, 0, f"{label} take pulls only what it passes on")
    }

    expect_clean(f"{label} take")

    reset()
    {
        var c = iter(Both<E>(10)).take(0)
        expect(c.remaining() == 0, f"{label} take(0) remaining")
        expect(!c.next()?, f"{label} take(0)")
        expect_pulls(0, 0, f"{label} take(0) pulls nothing")
        expect(!iter(Both<E>(10)).take(0).next_back()?, f"{label} take(0) from the back")
        expect_pulls(0, 0, f"{label} take(0) from the back pulls nothing")
    }

    expect_clean(f"{label} take(0)")

    reset()
    {
        var c = iter(Both<E>(3)).take(7)
        expect(c.remaining() == 3, f"{label} take past the end remaining")
        expect(ints_are(drain_keys(move(c)), [0, 1, 2]), f"{label} take past the end")
        expect_pulls(4, 0, f"{label} take past the end pulls to the end")
    }

    expect_clean(f"{label} take past the end")

    reset()
    {
        expect(!iter(Both<E>(0)).take(5).next()?, f"{label} take of nothing")
        expect_pulls(1, 0, f"{label} take of nothing asks once")
        PULLS = 0
        var c = iter(Both<E>(5)).take(5)
        expect(ints_are(drain_keys(move(c)), [0, 1, 2, 3, 4]), f"{label} take all")
        expect_pulls(5, 0, f"{label} take all does not ask for the end")
    }

    expect_clean(f"{label} take edges")
}

fn <E impl Elem> take_back(const label: string) {
    reset()
    {
        var c = iter(Both<E>(6)).take(3).rev()
        expect(ints_are(drain_keys(move(c)), [2, 1, 0]), f"{label} take from the back")
        expect_pulls(0, 3 + 3, f"{label} take drops the items past the cut")
    }

    expect_clean(f"{label} take reversed")

    reset()
    {
        var c = iter(Both<E>(6)).take(4)
        var a = kor(c.next())
        var b = kor(c.next_back())
        var d = kor(c.next())
        var e = kor(c.next_back())
        expect(a == 0 && b == 3 && d == 1 && e == 2, f"{label} take alternating")
        expect(c.remaining() == 0, f"{label} take remaining after four")
        expect(kor(c.next()) == -1, f"{label} take ends")
    }

    expect_clean(f"{label} take alternating")

    reset()
    {
        var c = iter(Both<E>(3)).take(7)
        expect(kor(c.next_back()) == 2 && c.remaining() == 2, f"{label} take past the end from the back")
        expect_pulls(0, 1, f"{label} nothing past the end is dropped")
    }

    expect_clean(f"{label} take past the end from the back")
}

fn <E impl Elem> skip_front(const label: string) {
    reset()
    {
        var c = iter(Both<E>(8)).skip(3)
        expect_pulls(0, 0, f"{label} skip is lazy")
        expect(c.remaining() == 5, f"{label} skip remaining")
        expect_pulls(0, 0, f"{label} remaining skips nothing")
        expect(kor(c.next()) == 3, f"{label} skip first")
        expect_pulls(4, 0, f"{label} skip pulled the skipped items and one")
        expect(c.remaining() == 4, f"{label} skip remaining after one")
        expect(ints_are(drain_keys(move(c)), [4, 5, 6, 7]), f"{label} skip rest")
        expect_pulls(9, 0, f"{label} skip pulls each item once")
    }

    expect_clean(f"{label} skip")

    reset()
    {
        var c = iter(Both<E>(4)).skip(0)
        expect(c.remaining() == 4, f"{label} skip(0) remaining")
        expect(ints_are(drain_keys(move(c)), [0, 1, 2, 3]), f"{label} skip(0)")
    }

    expect_clean(f"{label} skip(0)")

    reset()
    {
        var c = iter(Both<E>(3)).skip(9)
        expect(c.remaining() == 0, f"{label} skip past the end remaining")
        expect(!c.next()?, f"{label} skip past the end")
        expect_pulls(4, 0, f"{label} skip past the end pulls the items and the end")
    }

    expect_clean(f"{label} skip past the end")

    reset()
    {
        var c = iter(Both<E>(3)).skip(3)
        expect(c.remaining() == 0 && !c.next()?, f"{label} skip exactly all")
        expect(!iter(Both<E>(0)).skip(2).next()?, f"{label} skip of nothing")
    }

    expect_clean(f"{label} skip all")
}

fn <E impl Elem> skip_back(const label: string) {
    reset()
    {
        var c = iter(Both<E>(5)).skip(2).rev()
        expect(ints_are(drain_keys(move(c)), [4, 3, 2]), f"{label} skip from the back")
        expect_pulls(0, 3, f"{label} skip never reaches the skipped items")
    }

    expect_clean(f"{label} skip reversed")

    reset()
    {
        var c = iter(Both<E>(6)).skip(2)
        var a = kor(c.next_back())
        var b = kor(c.next())
        var d = kor(c.next_back())
        var e = kor(c.next())
        expect(a == 5 && b == 2 && d == 4 && e == 3, f"{label} skip alternating")
        expect(c.remaining() == 0, f"{label} skip remaining after four")
        expect(kor(c.next_back()) == -1, f"{label} skip meets")
    }

    expect_clean(f"{label} skip alternating")

    reset()
    {
        var c = iter(Both<E>(3)).skip(9)
        expect(!c.next_back()?, f"{label} skip past the end from the back")
        expect_pulls(0, 0, f"{label} skip past the end from the back pulls nothing")
    }

    expect_clean(f"{label} skip past the end from the back")
}

/// The inputs of the Rust tests, over slice iterators of integers.
fn rust_take_cases() {
    var xs: [i64] = [0, 1, 2, 3, 5, 13, 15, 16, 17, 19]
    var ys: [i64] = [0, 1, 2, 3, 5]
    var it = iter(xs.iter()).take(ys.size())
    expect(it.remaining() == ys.size(), "take(5) of ten, remaining")
    var i: usize = 0
    loop {
        var x? = it.next()
        if !x? {
            break
        }

        expect(*unwrap!(x) == ys[i], "take front item")
        i += 1
        expect(it.remaining() == ys.size() - i, "take front remaining")
    }

    expect(i == ys.size() && it.remaining() == 0, "take front ends at the count")

    var back = iter(xs.iter()).take(ys.size())
    var j: usize = 0
    loop {
        var x? = back.next_back()
        if !x? {
            break
        }

        j += 1
        expect(*unwrap!(x) == ys[ys.size() - j], "take back item")
        expect(back.remaining() == ys.size() - j, "take back remaining")
    }

    expect(j == ys.size() && back.remaining() == 0, "take back ends at the count")

    var four: [i64] = [0, 1, 2, 3]
    var sf = iter(four.iter()).take(5)
    expect(sf.remaining() == 4, "take(5) of four, remaining")
    var k: usize = 0
    loop {
        var x? = sf.next()
        if !x? {
            break
        }

        expect(*unwrap!(x) == four[k], "take short front item")
        k += 1
        expect(sf.remaining() == 4 - k, "take short front remaining")
    }

    expect(k == 4, "take short front count")
    var sb = iter(four.iter()).take(5)
    var m: usize = 0
    loop {
        var x? = sb.next_back()
        if !x? {
            break
        }

        m += 1
        expect(*unwrap!(x) == four[4 - m], "take short back item")
        expect(sb.remaining() == 4 - m, "take short back remaining")
    }

    expect(m == 4 && sb.remaining() == 0, "take short back count")

    // `nth` through a take: the position counts inside the cut.
    var five: [i64] = [0, 1, 2, 3, 4]
    var n1? = iter(five.iter()).take(3).nth(0)
    var n2? = iter(five.iter()).take(3).nth(2)
    var n3? = iter(five.iter()).take(3).nth(3)
    var n4? = iter(five.iter()).take(7).nth(3)
    var n5? = iter(five.iter()).take(7).nth(5)
    expect(n1? && *unwrap!(n1) == 0, "take nth(0)")
    expect(n2? && *unwrap!(n2) == 2 && !n3?, "take nth stops at the cut")
    expect(n4? && *unwrap!(n4) == 3 && !n5?, "take past the end nth")
    var b1? = iter(five.iter()).take(7).rev().nth(1)
    var b2? = iter(five.iter()).take(3).rev().nth(1)
    expect(b1? && *unwrap!(b1) == 3 && b2? && *unwrap!(b2) == 1, "take rev nth")
}

fn rust_skip_cases() {
    var xs: [i64] = [0, 1, 2, 3, 5, 13, 15, 16, 17, 19, 20, 30]
    var ys: [i64] = [13, 15, 16, 17, 19, 20, 30]
    var it = iter(xs.iter()).skip(5)
    var i: usize = 0
    loop {
        var x? = it.next()
        if !x? {
            break
        }

        expect(*unwrap!(x) == ys[i], "skip(5) item")
        i += 1
        expect(it.remaining() == xs.size() - 5 - i, "skip(5) remaining")
    }

    expect(i == ys.size() && it.remaining() == 0, "skip(5) ends")

    // Reading a skipped reversed chain from both ends.
    var d = iter(xs.iter()).rev().skip(5)
    var d1? = d.next()
    var d2? = d.next_back()
    var d3? = d.next()
    var d4? = d.next_back()
    var d5? = d.next()
    var d6? = d.next_back()
    var d7? = d.next()
    var d8? = d.next()
    expect(d1? && *unwrap!(d1) == 15 && d2? && *unwrap!(d2) == 0, "skip over rev, first two")
    expect(d3? && *unwrap!(d3) == 13 && d4? && *unwrap!(d4) == 1, "skip over rev, next two")
    expect(d5? && *unwrap!(d5) == 5 && d6? && *unwrap!(d6) == 2, "skip over rev, next two again")
    expect(d7? && *unwrap!(d7) == 3 && !d8?, "skip over rev ends")

    var r = iter(xs.iter()).rev().skip(5).rev()
    var r1? = r.next()
    var r2? = r.next_back()
    expect(r1? && *unwrap!(r1) == 0 && r2? && *unwrap!(r2) == 15, "rev of skip over rev")

    var back = iter(xs.iter()).skip(5).rev()
    var want: [i64] = [30, 20, 19, 17, 16, 15, 13]
    for var k: usize = 0; k < want.size(); ++k {
        var x? = back.next()
        expect(x? && *unwrap!(x) == want[k], "skip then rev, in order")
    }

    expect(!back.next()?, "skip then rev ends")
    var lst? = iter(xs.iter()).skip(5).rev().last()
    expect(lst? && *unwrap!(lst) == 13, "skip then rev, last")

    // nth: the position counts after the skip.
    var a? = iter(xs.iter()).skip(0).nth(0)
    var b? = iter(xs.iter()).skip(0).nth(2)
    var c? = iter(xs.iter()).skip(5).nth(0)
    var e? = iter(xs.iter()).skip(5).nth(2)
    var f? = iter(xs.iter()).skip(12).nth(0)
    expect(a? && *unwrap!(a) == 0 && b? && *unwrap!(b) == 2, "skip(0) nth")
    expect(c? && *unwrap!(c) == 13 && e? && *unwrap!(e) == 16 && !f?, "skip(5) nth")

    // count and last for a skip at, below and above the length.
    expect(iter(xs.iter()).skip(0).count() == 12 && iter(xs.iter()).skip(1).count() == 11, "skip count")
    expect(iter(xs.iter()).skip(11).count() == 1 && iter(xs.iter()).skip(12).count() == 0 && iter(xs.iter()).skip(13).count() == 0, "skip count at the end")
    var l0? = iter(xs.iter()).skip(0).last()
    var l1? = iter(xs.iter()).skip(11).last()
    var l2? = iter(xs.iter()).skip(12).last()
    var l3? = iter(xs.iter()).skip(13).last()
    expect(l0? && *unwrap!(l0) == 30 && l1? && *unwrap!(l1) == 30 && !l2? && !l3?, "skip last")
}

fn composed() {
    var v: [i64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    expect(ints_are(iter(v.iter()).skip(2).take(3).copied().collect<[i64]>(), [2, 3, 4]), "skip then take")
    expect(ints_are(iter(v.iter()).take(5).skip(2).copied().collect<[i64]>(), [2, 3, 4]), "take then skip")
    expect(ints_are(iter(v.iter()).take(4).skip(9).copied().collect<[i64]>(), []), "take then skip past it")
    expect(ints_are(iter(v.iter()).skip(8).take(9).copied().collect<[i64]>(), [8, 9]), "skip then take past the end")
    expect(ints_are(iter(v.iter()).skip(1).take(8).skip(1).take(6).copied().collect<[i64]>(), [2, 3, 4, 5, 6, 7]), "four deep")
    expect(ints_are(iter(v.iter()).skip(2).take(5).rev().copied().collect<[i64]>(), [6, 5, 4, 3, 2]), "skip take reversed")
    expect(ints_are(iter(v.iter()).take(7).skip(2).rev().copied().collect<[i64]>(), [6, 5, 4, 3, 2]), "take skip reversed")
    expect(iter(v.iter()).skip(2).take(5).remaining() == 5, "skip take remaining")
    expect(iter(v.iter()).take(5).skip(2).remaining() == 3, "take skip remaining")
    expect(iter(v.iter()).skip(2).take(50).remaining() == 8, "skip take past the end remaining")

    var c = iter(v.iter()).skip(2).take(5)
    var x? = c.next()
    var y? = c.next_back()
    expect(x? && y? && *unwrap!(x) == 2 && *unwrap!(y) == 6 && c.remaining() == 3, "skip take, both ends")

    var w: [string] = ["a", "b", "c", "d", "e"]
    var s = iter(w.iter()).skip(1).take(3).map<usize>(len_of).sum()
    expect(s == 3, "skip take over strings")
}

fn len_of(p: *const string) -> usize = p->size()

fn move_only() {
    reset()
    {
        var a = iter(Both<Counted>(8)).skip(2).take(3).collect<[Counted]>()
        expect(keys_are(a, [2, 3, 4]), "skip take move-only items")
    }

    expect_clean("skip take move-only items")

    reset()
    {
        var a = iter(Both<Counted>(8)).take(5).skip(1).rev().collect<[Counted]>()
        expect(keys_are(a, [4, 3, 2, 1]), "take skip reversed, move-only items")
    }

    expect_clean("take skip reversed move-only")

    reset()
    {
        var c = iter(Both<Counted>(8)).skip(2).take(4)
        var a? = c.next()
        var b? = c.next_back()
        expect(a? && b?, "abandoned take skip items")
    }

    expect_clean("abandoned skip take")

    reset()
    {
        var c = iter(Fwd<Counted>(8)).skip(3).take(2)
        var a? = c.next()
        expect(a?, "abandoned forward item")
    }

    expect_clean("abandoned forward skip take")
}

fn main() -> i32 {
    take_front<i64>("i64")
    take_front<string>("string")
    take_front<Counted>("Counted")
    take_back<i64>("i64")
    take_back<string>("string")
    take_back<Counted>("Counted")
    skip_front<i64>("i64")
    skip_front<string>("string")
    skip_front<Counted>("Counted")
    skip_back<i64>("i64")
    skip_back<string>("string")
    skip_back<Counted>("Counted")
    rust_take_cases()
    rust_skip_cases()
    composed()
    move_only()
    return finish()
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
