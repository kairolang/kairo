// `peekable` and `peek`: peeking pulls one item and holds it, a second peek
// does not pull again, `next` after a peek hands the held item over, a peek
// at the end reports the end and the source is not asked again after it,
// peeking between every `next`, the held item is destroyed once when the
// chain is dropped, and item types of different sizes and layouts (a byte, a
// boolean, a pair, a string, a move-only class) are held and read back
// intact. A peekable chain is not DoubleEnded and not ExactSize:
// capabilities.k.
//
// Cases from Rust library/coretests/tests/iter/adapters/peekable.rs
//   (test_iterator_peekable, test_iterator_peekable_count,
//   test_iterator_peekable_nth, test_iterator_peekable_last,
//   test_iterator_peekable_fold, test_iterator_peekable_remember_peek_none_1,
//   _2, _3)

import std::iter::*
import std::io
import self::Inputs::probe::*

fn <E impl Elem> peek_cases(const label: string) {
    reset()
    {
        var c = iter(Fwd<E>(3)).peekable()
        expect_pulls(0, 0, f"{label} peekable is lazy")
        var a? = c.peek()
        expect(a? && unwrap!(a)->key() == 0, f"{label} peek first")
        expect_pulls(1, 0, f"{label} peek pulled one")
        var b? = c.peek()
        expect(b? && unwrap!(b)->key() == 0, f"{label} peek again")
        expect_pulls(1, 0, f"{label} a second peek pulls nothing")
        expect(kor(c.next()) == 0, f"{label} next after peek")
        expect_pulls(1, 0, f"{label} next after peek pulls nothing")
        expect(kor(c.next()) == 1, f"{label} next without peek")
        expect_pulls(2, 0, f"{label} next pulls one")
        var d? = c.peek()
        expect(d? && unwrap!(d)->key() == 2, f"{label} peek last")
        expect(kor(c.next()) == 2, f"{label} next last")
        var e? = c.peek()
        expect(!e?, f"{label} peek at the end")
        expect_pulls(4, 0, f"{label} peek at the end pulled the end once")
        var f? = c.peek()
        expect(!f? && !c.next()? && !c.peek()?, f"{label} peek and next after the end")
        expect_pulls(4, 0, f"{label} the source is not asked after its end")
    }

    expect_clean(f"{label} peekable")

    reset()
    {
        var c = iter(Fwd<E>(0)).peekable()
        var a? = c.peek()
        expect(!a?, f"{label} peek of nothing")
        expect(!c.next()?, f"{label} next of nothing")
        expect_pulls(1, 0, f"{label} peek and next of nothing pulled once")
    }

    expect_clean(f"{label} peekable empty")

    reset()
    {
        var c = iter(Fwd<E>(5)).peekable()
        var total: i64 = 0
        loop {
            var p? = c.peek()
            if !p? {
                break
            }

            var seen = unwrap!(p)->key()
            var got = kor(c.next())
            expect(seen == got, f"{label} peek equals the next item")
            total += got
        }

        expect(total == 10, f"{label} peeking before every next")
        expect_pulls(6, 0, f"{label} peeking before every next pulls once per item")
    }

    expect_clean(f"{label} peek before every next")

    reset()
    {
        var c = iter(Fwd<E>(5)).peekable()
        var a? = c.peek()
        expect(a?, f"{label} held item")
    }

    expect_clean(f"{label} dropped with a held item")

    reset()
    {
        var c = iter(Fwd<E>(5)).peekable()
        var a? = c.next()
        var b? = c.peek()
        expect(a? && b?, f"{label} next then peek")
    }

    expect_clean(f"{label} dropped after next and peek")

    reset()
    {
        var c = iter(Fwd<E>(2)).peekable()
        var a? = c.next()
        var b? = c.next()
        var d? = c.peek()
        expect(a? && b? && !d?, f"{label} peek of the end held, then dropped")
    }

    expect_clean(f"{label} dropped with the end held")
}

fn peek_then_consumers() {
    var v: [i64] = [1, 2, 3, 4, 5]
    var c = iter(v.iter()).copied().peekable()
    var p? = c.peek()
    expect(p? && *unwrap!(p) == 1, "peek before count")
    expect(c.count() == 5, "count after peek keeps the held item")

    var d = iter(v.iter()).copied().peekable()
    var q? = d.peek()
    expect(q?, "peek before fold")
    expect(d.fold<i64>(0, add) == 15, "fold after peek keeps the held item")

    var e = iter(v.iter()).copied().peekable()
    var r? = e.peek()
    expect(r?, "peek before nth")
    var n? = e.nth(1)
    expect(n? && unwrap!(n) == 2, "nth after peek counts the held item")

    var f = iter(v.iter()).copied().peekable()
    var s? = f.peek()
    expect(s?, "peek before collect")
    expect(ints_are(f.collect<[i64]>(), [1, 2, 3, 4, 5]), "collect after peek keeps the held item")

    var g = iter(v.iter()).copied().peekable().map<i64>(key_plus_100<i64>)
    expect((g.next() ?? -1) == 101, "map over a peekable")
    CALLS = 0
}

fn add(a: i64, x: i64) -> i64 = a + x

/// A held end is remembered: consumers that run after a peek found the end do
/// not ask the source again (`last`, `nth`, `count`, `fold`, `collect`).
fn held_end_is_remembered() {
    reset()
    {
        var c = iter(Fwd<i64>(1)).peekable()
        var a? = c.next()
        var p? = c.peek()
        expect(a? && !p?, "the end is found")
        expect(!c.last()?, "last after a held end")
    }

    expect_clean("last after a held end")

    reset()
    {
        var c = iter(Fwd<i64>(1)).peekable()
        c.next()
        var p? = c.peek()
        expect(!p? && !c.nth(0)?, "nth after a held end")
    }

    expect_clean("nth after a held end")

    reset()
    {
        var c = iter(Fwd<i64>(0)).peekable()
        var p? = c.peek()
        expect(!p? && c.count() == 0, "count after a held end")
        var d = iter(Fwd<i64>(0)).peekable()
        var q? = d.peek()
        expect(!q? && d.fold<i64>(5, add) == 5, "fold after a held end")
        var e = iter(Fwd<i64>(0)).peekable()
        var r? = e.peek()
        expect(!r? && e.collect<[i64]>().size() == 0, "collect after a held end")
    }

    expect_clean("consumers after a held end")

    reset()
    {
        var c = iter(Fwd<i64>(1)).peekable()
        var p? = c.peek()
        expect(p? && (c.nth(0) ?? -1) == 0, "nth(0) after a peek takes the held item")
    }

    expect_clean("nth(0) after a peek")
}

fn gen_bytes() -> yield u8 {
    yield 7
    yield 255
}

fn gen_bools() -> yield bool {
    yield true
    yield false
}

fn gen_pairs() -> yield (i64, u8) {
    yield (5, 6)
    yield (7, 8)
}

fn gen_strings() -> yield string {
    yield "first"
    yield "second"
}

fn item_layouts() {
    var b = iter(gen_bytes()).peekable()
    var b0? = b.peek()
    expect(b0? && *unwrap!(b0) == 7, "peek a byte")
    expect((b.next() ?? 0) == 7, "byte held then taken")
    var b1? = b.peek()
    expect(b1? && *unwrap!(b1) == 255, "peek the largest byte")
    expect((b.next() ?? 0) == 255 && !b.peek()?, "byte stream ends")

    var t = iter(gen_bools()).peekable()
    var t0? = t.peek()
    expect(t0? && *unwrap!(t0), "peek true")
    var t1 = t.next() ?? false
    var t2? = t.peek()
    expect(t1 && t2? && !*unwrap!(t2), "peek false")
    var t3 = t.next() ?? true
    expect(!t3 && !t.peek()?, "bool stream ends")

    var p = iter(gen_pairs()).peekable()
    var p0? = p.peek()
    expect(p0? && unwrap!(p0)->0 == 5 && unwrap!(p0)->1 == 6, "peek a pair")
    var p1? = p.next()
    expect(p1? && unwrap!(p1).0 == 5 && unwrap!(p1).1 == 6, "pair held then taken")
    var p2? = p.next()
    expect(p2? && unwrap!(p2).0 == 7 && unwrap!(p2).1 == 8 && !p.peek()?, "pair stream ends")

    var s = iter(gen_strings()).peekable()
    var s0? = s.peek()
    expect(s0? && *unwrap!(s0) == "first", "peek a string")
    var s1? = s.next()
    expect(s1? && unwrap!(s1) == "first", "string held then taken")
    var s2? = s.peek()
    expect(s2? && *unwrap!(s2) == "second", "peek the second string")
}

fn move_only() {
    reset()
    {
        var v = iter(Both<Counted>(4)).peekable().collect<[Counted]>()
        expect(keys_are(v, [0, 1, 2, 3]), "peekable collects move-only items")
    }

    expect_clean("peekable collect")

    reset()
    {
        var c = iter(Both<Counted>(4)).peekable()
        var p? = c.peek()
        expect(p?, "peeked move-only item")
        var v = c.collect<[Counted]>()
        expect(keys_are(v, [0, 1, 2, 3]), "collect after peek, move-only")
    }

    expect_clean("collect after peek")

    reset()
    {
        var c = iter(Both<Counted>(4)).peekable().take(2)
        var p? = c.next()
        expect(p?, "take over a peekable")
    }

    expect_clean("peekable under take, abandoned")
}

fn main() -> i32 {
    peek_cases<i64>("i64")
    peek_cases<string>("string")
    peek_cases<Counted>("Counted")
    peek_then_consumers()
    held_end_is_remembered()
    item_layouts()
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
