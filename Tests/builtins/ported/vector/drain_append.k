// drain over every kind of range, taken from either end, dropped early and
// run out; append into and from empty vectors and with spare room; extend_from
// with a slice of the vector itself, which must survive the reallocation the
// extension causes. Counted and RCounted cases check that a drain destroys
// exactly the elements it did not hand out, that append moves elements and
// copies none, and that extend_from copies each element once.
//
// Cases from libc++ test/std/containers/sequences/vector/vector.modifiers/
//   (erase_iter_iter, append_range, insert_iter_iter_iter)
// Cases from Rust library/alloctests/tests/vec.rs
//
// differs from Rust: `drain` takes a `Range<usize>`, so the open ranges
// `drain(..)`, `drain(a..)` and `drain(..b)` are written with explicit
// bounds. A drain is advanced with `next` and `next_back` (it is not a
// `for` target) and `remaining()` counts what is left.

import self::inputs::counted::*

/// Everything the drain yields from the front, in order.
fn <E impl Elem> take_all(d: Drain<E>) -> [i64] {
    var got: [i64]
    loop {
        var x? = d.next()
        if x? {
            got.push(unwrap!(x).key())
        } else {
            break
        }
    }

    return got
}

fn <E impl Elem> drain_ranges(const tag: string) {
    reset()
    {
        var v = fill<E>(8)
        var a = take_all(v.drain(0..v.size()))
        expect(v.is_empty() && v.capacity() >= 8, f"{tag}: draining everything leaves an empty vector with its block")
        expect(a.size() == 8 && a[0] == 0 && a[7] == 7, f"{tag}: draining everything yields everything in order")
        var w = fill<E>(8)
        var b = take_all(w.drain(0..3))
        expect(keys_are(w, [3, 4, 5, 6, 7]) && b.size() == 3 && b[2] == 2, f"{tag}: drain a prefix")
        var x = fill<E>(8)
        var c = take_all(x.drain(5..8))
        expect(keys_are(x, [0, 1, 2, 3, 4]) && c.size() == 3 && c[0] == 5, f"{tag}: drain a suffix")
        var y = fill<E>(8)
        var d = take_all(y.drain(2..6))
        expect(keys_are(y, [0, 1, 6, 7]) && d.size() == 4 && d[3] == 5, f"{tag}: drain a middle range")
        var z = fill<E>(8)
        var e = take_all(z.drain(2..=5))
        expect(keys_are(z, [0, 1, 6, 7]) && e.size() == 4, f"{tag}: drain an inclusive range")
        var q = fill<E>(8)
        var f = take_all(q.drain(4..4))
        expect(keys_are(q, [0, 1, 2, 3, 4, 5, 6, 7]) && f.is_empty(), f"{tag}: drain an empty range in the middle")
        var r = fill<E>(8)
        var g = take_all(r.drain(8..8))
        expect(r.size() == 8 && g.is_empty(), f"{tag}: drain an empty range at the end")
        var s = fill<E>(8)
        var h = take_all(s.drain(0..0))
        expect(s.size() == 8 && h.is_empty(), f"{tag}: drain an empty range at the start")
        var t = fill<E>(1)
        var i = take_all(t.drain(0..1))
        expect(t.is_empty() && i.size() == 1, f"{tag}: drain the only element")
        var u: [E]
        var j = take_all(u.drain(0..0))
        expect(u.is_empty() && j.is_empty(), f"{tag}: drain of an empty vector")
        var k = fill<E>(5)
        var l = take_all(k.drain(4..=4))
        expect(keys_are(k, [0, 1, 2, 3]) && l.size() == 1 && l[0] == 4, f"{tag}: drain the last element inclusively")
    }

    expect_clean(f"{tag}: drain ranges")
}

fn <E impl Elem> drain_both_ends(const tag: string) {
    reset()
    {
        var v = fill<E>(10)
        {
            var d = v.drain(2..8)
            expect(d.remaining() == 6, f"{tag}: remaining before any step")
            var f1? = d.next()
            var b1? = d.next_back()
            var f2? = d.next()
            var b2? = d.next_back()
            expect(f1? && b1? && f2? && b2?, f"{tag}: four steps from both ends")
            if f1? && b1? && f2? && b2? {
                expect(unwrap!(f1).key() == 2 && unwrap!(b1).key() == 7, f"{tag}: first front and back")
                expect(unwrap!(f2).key() == 3 && unwrap!(b2).key() == 6, f"{tag}: second front and back")
            }

            expect(d.remaining() == 2, f"{tag}: remaining after four steps")
            var m1? = d.next_back()
            var m2? = d.next()
            expect(m1? && m2? && unwrap!(m1).key() == 5 && unwrap!(m2).key() == 4, f"{tag}: the last two meet in the middle")
            expect(d.remaining() == 0, f"{tag}: nothing remaining")
            var e1? = d.next()
            var e2? = d.next_back()
            expect(!e1? && !e2?, f"{tag}: both ends are null when run out")
        }

        expect(keys_are(v, [0, 1, 8, 9]), f"{tag}: the kept elements close up")
        var w = fill<E>(6)
        {
            var d = w.drain(1..5)
            var a? = d.next_back()
            var b? = d.next_back()
            expect(a? && b? && unwrap!(a).key() == 4 && unwrap!(b).key() == 3, f"{tag}: back only")
        }

        expect(keys_are(w, [0, 5]), f"{tag}: dropped after reading from the back")
        var x = fill<E>(6)
        {
            var d = x.drain(0..6)
            var a? = d.next_back()
            var b? = d.next()
            expect(a? && b? && unwrap!(a).key() == 5 && unwrap!(b).key() == 0, f"{tag}: a full drain from both ends")
        }

        expect(x.is_empty(), f"{tag}: a full drain dropped early empties the vector")
    }

    expect_clean(f"{tag}: drain from both ends")
}

fn <E impl Elem> drain_dropped_early(const tag: string) {
    reset()
    {
        var v = fill<E>(10)
        {
            var d = v.drain(3..7)
            var a? = d.next()
            expect(a? && unwrap!(a).key() == 3, f"{tag}: first element of the drain")
        }

        expect(keys_are(v, [0, 1, 2, 7, 8, 9]), f"{tag}: dropped after one step")
        var w = fill<E>(10)
        {
            var d = w.drain(3..7)
        }

        expect(keys_are(w, [0, 1, 2, 7, 8, 9]), f"{tag}: dropped without a step")
        var cap = w.capacity()
        w.push(E::make(50))
        expect(keys_are(w, [0, 1, 2, 7, 8, 9, 50]) && w.capacity() == cap, f"{tag}: the vector is usable after the drain")
        var moved = fill<E>(10)
        {
            var d = moved.drain(1..4)
            var d2 = move(d)
            var a? = d2.next()
            expect(a? && unwrap!(a).key() == 1 && d2.remaining() == 2, f"{tag}: a moved drain carries on")
        }

        expect(keys_are(moved, [0, 4, 5, 6, 7, 8, 9]), f"{tag}: a moved drain closes the gap once")
    }

    expect_clean(f"{tag}: drain dropped early")
}

fn drain_destroys_the_rest() {
    reset()
    {
        var v = fill<Counted>(10)
        {
            var d = v.drain(2..8)
            var a? = d.next()
            var b? = d.next_back()
            expect(LOGGED == 0, "taking elements out of a drain destroys none")
        }

        expect(LOGGED == 6, "the four a drain still held are destroyed when it ends, and the two taken when they go")
        expect(LIVE == 4 && COPIES == 0, "four are kept, none copied")
    }

    expect_clean("drain drops the rest of a Counted range")
    reset()
    {
        var v = fill<RCounted>(10)
        {
            var d = v.drain(0..10)
        }

        expect(LIVE == 0 && v.is_empty(), "dropping a full drain destroys every relocatable element")
        var sum: i64 = 0
        for var i: usize = 0; i < LOGGED; ++i {
            sum += LOG[i]
        }

        expect(LOGGED == 10 && sum == 45, "every element was destroyed once")
    }

    expect_clean("drain drops the rest of an RCounted range")
}

fn <E impl Elem> collected_drain(const tag: string) {
    reset()
    {
        var v = fill<E>(6)
        var got = Vector<E>::from_iter(v.drain(1..5), 4)
        expect(keys_are(got, [1, 2, 3, 4]) && keys_are(v, [0, 5]), f"{tag}: a drain collected by from_iter")
    }

    expect_clean(f"{tag}: collected drain")
}

fn <E impl Elem> append_cases(const tag: string) {
    reset()
    {
        var a = fill<E>(3)
        var b = fill<E>(3)
        a.append(move(b))
        expect(keys_are(a, [0, 1, 2, 0, 1, 2]), f"{tag}: append to a non-empty vector")
        var e: [E]
        a.append(move(e))
        expect(a.size() == 6, f"{tag}: append of an empty vector")
        var into: [E]
        var src = fill<E>(5)
        var sp = src.data()
        into.append(move(src))
        expect(keys_are(into, [0, 1, 2, 3, 4]), f"{tag}: append into an empty vector")
        expect(into.data() == sp, f"{tag}: an empty vector takes the block of what it appends")
        var roomy = Vector<E>::with_capacity(100)
        var rp = roomy.data()
        roomy.append(fill<E>(4))
        expect(keys_are(roomy, [0, 1, 2, 3]) && roomy.capacity() >= 100, f"{tag}: appending into reserved room keeps it")
        roomy.append(fill<E>(3))
        expect(keys_are(roomy, [0, 1, 2, 3, 0, 1, 2]) && roomy.data() == rp, f"{tag}: a second append fits in place")
        var big = fill<E>(100)
        var more = fill<E>(1000)
        big.append(move(more))
        expect(big.size() == 1100 && big[99].key() == 99 && big[100].key() == 0 && big[1099].key() == 999, f"{tag}: append that reallocates")
        var one = fill<E>(1)
        var two = fill<E>(1)
        one.append(move(two))
        expect(keys_are(one, [0, 0]), f"{tag}: append of one to one")
    }

    expect_clean(f"{tag}: append")
}

fn append_counts() {
    reset()
    {
        var a = fill<Counted>(10)
        var b = fill<Counted>(10)
        var before = COPIES
        a.append(move(b))
        expect(COPIES == before && LIVE == 20, "append copies no element")
    }

    expect_clean("append counts")
    reset()
    {
        var a: [Counted]
        var b = fill<Counted>(10)
        var m = MOVES
        a.append(move(b))
        expect(MOVES == m && LIVE == 10, "appending to empty moves no element")
    }

    expect_clean("append to empty counts")
}

fn <E impl Elem> extend_from_cases(const tag: string) requires E impl Copyable {
    reset()
    {
        var v = fill<E>(3)
        var w = fill<E>(2)
        v.extend_from(w[0..2])
        expect(keys_are(v, [0, 1, 2, 0, 1]), f"{tag}: extend_from a range of another vector")
        v.extend_from(w[1..1])
        expect(v.size() == 5, f"{tag}: extend_from an empty range")
        var into: [E]
        into.extend_from(w[0..2])
        expect(keys_are(into, [0, 1]), f"{tag}: extend_from into an empty vector")
        var s = fill<E>(3)
        s.extend_from(s[1..3])
        expect(keys_are(s, [0, 1, 2, 1, 2]), f"{tag}: extend_from a middle range of itself")
        s.extend_from(s[0..2])
        expect(keys_are(s, [0, 1, 2, 1, 2, 0, 1]), f"{tag}: extend_from a prefix of itself")
        var grow = Vector<E>::with_capacity(4)
        for var i: i64 = 0; i < 4; ++i {
            grow.push(E::make(i))
        }

        grow.extend_from(grow[2..4])
        expect(keys_are(grow, [0, 1, 2, 3, 2, 3]), f"{tag}: the slice survives the reallocation")
        for var i: i64 = 0; i < 6; ++i {
            grow.extend_from(grow[0..grow.size()])
        }

        expect(grow.size() == 6 * 64 && grow[6 * 64 - 1].key() == 3 && grow[6 * 32].key() == 0, f"{tag}: repeated doubling through a full-range slice")
    }

    expect_clean(f"{tag}: extend_from")
}

/// The same extensions with the vector itself as the argument, in a function
/// that is not generic.
fn extend_from_whole_concrete() {
    var w: [i32] = [0, 1]
    var v: [i32] = [7]
    v.extend_from(w)
    expect(v.size() == 3 && v[2] == 1, "i32: extend_from another vector")
    var whole: [i32] = [0, 1, 2]
    whole.extend_from(whole)
    expect(whole.size() == 6 && whole[3] == 0 && whole[5] == 2, "i32: extend_from the whole of itself")
    var grow = Vector<i32>::with_capacity(3)
    grow.push(1)
    grow.push(2)
    grow.push(3)
    grow.extend_from(grow)
    expect(grow.size() == 6 && grow[5] == 3 && grow[3] == 1, "i32: the whole vector survives the reallocation")
    for var i: i64 = 0; i < 6; ++i {
        grow.extend_from(grow)
    }

    expect(grow.size() == 6 * 64 && grow[6 * 64 - 1] == 3, "i32: repeated doubling")
    var s: [string] = ["a", "b"]
    s.extend_from(s)
    s.extend_from(s)
    expect(s.size() == 8 && s[7] == "b" && s[4] == "a", "string: extend_from itself twice")
    var e: [string]
    s.extend_from(e)
    expect(s.size() == 8, "string: extend_from an empty vector")
}

fn extend_counts() {
    reset()
    {
        var v = fill<Counted>(4)
        var m = MOVES
        v.extend_from(v[0..4])
        expect(COPIES == 4 && LIVE == 8, "extend_from copies each element once")
        expect(MOVES >= m, "the reallocation may move")
    }

    expect_clean("extend_from counts")
}

fn main() -> i32 {
    drain_ranges<i32>("i32")
    drain_ranges<string>("string")
    drain_ranges<Counted>("Counted")
    drain_ranges<RCounted>("RCounted")
    drain_both_ends<i32>("i32")
    drain_both_ends<string>("string")
    drain_both_ends<Counted>("Counted")
    drain_both_ends<RCounted>("RCounted")
    drain_dropped_early<i32>("i32")
    drain_dropped_early<string>("string")
    drain_dropped_early<Counted>("Counted")
    drain_dropped_early<RCounted>("RCounted")
    drain_destroys_the_rest()
    collected_drain<i32>("i32")
    collected_drain<string>("string")
    collected_drain<Counted>("Counted")
    collected_drain<RCounted>("RCounted")
    append_cases<i32>("i32")
    append_cases<string>("string")
    append_cases<Counted>("Counted")
    append_cases<RCounted>("RCounted")
    append_counts()
    extend_from_cases<i32>("i32")
    extend_from_cases<string>("string")
    extend_from_cases<Counted>("Counted")
    extend_from_cases<RCounted>("RCounted")
    extend_counts()
    extend_from_whole_concrete()
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
