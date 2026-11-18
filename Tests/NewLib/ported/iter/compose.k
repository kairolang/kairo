// Adapters composed two, three and four deep: the result of each chain, the
// exact number of items pulled from the source, nothing pulled or run while
// the chain is only built, both ends read alternately through a chain that
// supports them, and move-only items delivered once (collected, or dropped
// when the chain is abandoned half-way through, with a buffered item or a
// live sub-iterator in the middle).
//
// Cases from Rust library/coretests/tests/iter/adapters/ (the cases of
//   one adapter over another: skip then take, filter then map, zip then
//   enumerate, chain then rev)
// Cases from Rust library/coretests/tests/iter/traits/double_ended.rs
//   (double-ended chains of several adapters)

import std::iter::*
import std::io
import self::Inputs::probe::*

fn building_pulls_nothing() {
    reset()
    {
        var a = iter(Fwd<i64>(9)).map<i64>(key_of<i64>).filter(is_even<i64>).skip(2).take(3).step_by(2).enumerate()
        var b = iter(Fwd<i64>(9)).take_while(below_5<i64>).skip_while(below_3<i64>).peekable()
        var c = iter(Fwd<i64>(9)).chain(Fwd<i64>(9)).zip(Fwd<i64>(9)).flat_map<Fwd<i64>>(pair_source)
        var d = iter(Both<i64>(9)).map<i64>(key_of<i64>).skip(1).take(4).enumerate().rev()
        expect_pulls(0, 0, "building chains pulls nothing")
        expect(CALLS == 0, "building chains runs no callback")
        expect(SOURCES == 6, "building chains holds every source")
    }

    expect_clean("building chains")
    CALLS = 0
}

fn pair_source(p: (i64, i64)) -> Fwd<i64> {
    CALLS += 1
    return Fwd<i64>(p.0)
}

fn deep_results() {
    expect(ints_are(iter(Both<i64>(10)).map<i64>(key_plus_100<i64>).filter(is_even<i64>).take(3).collect<[i64]>(), [100, 102, 104]), "map filter take")
    CALLS = 0
    expect(ints_are(iter(Both<i64>(10)).skip(2).map<i64>(key_plus_100<i64>).take(3).collect<[i64]>(), [102, 103, 104]), "skip map take")
    expect(ints_are(iter(Both<i64>(10)).skip(2).take(5).enumerate().map<i64>(indexed<i64>).collect<[i64]>(), [2, 1003, 2004, 3005, 4006]), "skip take enumerate map")
    expect(ints_are(iter(Both<i64>(6)).zip(Both<i64>(4)).map<i64>(paired<i64, i64>).skip(1).collect<[i64]>(), [1001, 2002, 3003]), "zip map skip")
    expect(ints_are(iter(Both<i64>(3)).chain(Both<i64>(3)).skip(2).take(3).collect<[i64]>(), [2, 0, 1]), "chain skip take")
    expect(ints_are(iter(Both<i64>(5)).flat_map<Fwd<i64>>(fwd_of<i64, i64>).filter(is_odd<i64>).step_by(2).collect<[i64]>(), [1, 1]), "flat_map filter step_by")
    expect(ints_are(iter(Both<i64>(9)).take_while(below_5<i64>).map<i64>(key_plus_100<i64>).enumerate().map<i64>(indexed<i64>).collect<[i64]>(), [100, 1101, 2102, 3103, 4104]), "take_while map enumerate map")
    expect(ints_are(iter(Both<i64>(9)).skip_while(below_3<i64>).filter(is_even<i64>).take(2).collect<[i64]>(), [4, 6]), "skip_while filter take")
    expect(ints_are(iter(Both<i64>(8)).skip(1).take(6).enumerate().rev().map<i64>(indexed<i64>).collect<[i64]>(), [5006, 4005, 3004, 2003, 1002, 1]), "skip take enumerate rev")
    expect(ints_are(iter(Both<i64>(8)).enumerate().rev().skip(2).map<i64>(indexed<i64>).collect<[i64]>(), [5005, 4004, 3003, 2002, 1001, 0]), "enumerate rev skip")
    expect(ints_are(iter(Both<i64>(8)).zip(Both<i64>(5)).rev().take(2).map<i64>(paired<i64, i64>).collect<[i64]>(), [4004, 3003]), "zip rev take")
    expect(ints_are(iter(Both<i64>(8)).map<i64>(key_of<i64>).rev().skip(1).take(3).collect<[i64]>(), [6, 5, 4]), "map rev skip take")
    expect(ints_are(iter(Both<i64>(6)).chain(Both<i64>(2)).rev().filter(is_even<i64>).collect<[i64]>(), [0, 4, 2, 0]), "chain rev filter")
    expect(ints_are(iter(Both<i64>(6)).peekable().skip(1).step_by(2).collect<[i64]>(), [1, 3, 5]), "peekable skip step_by")
    expect(iter(Both<i64>(100)).filter(is_even<i64>).map<i64>(key_of<i64>).skip(10).step_by(7).take(4).count() == 4, "five deep count")
    CALLS = 0
}

fn deep_pulls() {
    // Evens 0 2 4 6; skip one; take three: 2 4 6. The source is pulled
    // through 6 and not past it.
    reset()
    {
        var v = iter(Fwd<i64>(20)).filter(is_even<i64>).skip(1).take(3).collect<[i64]>()
        expect(ints_are(v, [2, 4, 6]), "filter skip take")
        expect_pulls(7, 0, "filter skip take pulls through the last item taken")
    }

    expect_clean("filter skip take")
    CALLS = 0

    reset()
    {
        expect(iter(Fwd<i64>(20)).map<i64>(key_plus_100<i64>).enumerate().take(2).count() == 2, "map enumerate take")
        expect_pulls(2, 0, "map enumerate take pulls two")
        PULLS = 0
        expect(iter(Fwd<i64>(20)).skip(5).take(2).step_by(2).count() == 1, "skip take step_by")
        expect_pulls(7, 0, "skip take step_by pulls the skipped items and the two, and no more")
    }

    expect_clean("deep pulls")
    CALLS = 0

    reset()
    {
        var c = iter(Both<i64>(10)).skip(2).take(5).enumerate()
        var a? = c.next()
        expect_pulls(3, 0, "skip take enumerate first item")
        var b? = c.next_back()
        expect(c.remaining() == 3, "skip take enumerate remaining")
        // The seven items past the cut are dropped from the back first.
        expect(BACKS == 1 + 3, "taking from the back drops what lies past the cut")
        expect(a? && b? && unwrap!(a).0 == 0 && unwrap!(a).1 == 2 && unwrap!(b).0 == 4 && unwrap!(b).1 == 6, "skip take enumerate ends")
    }

    expect_clean("skip take enumerate ends")
}

fn both_ends_through_a_chain() {
    reset()
    {
        var c = iter(Both<i64>(10)).map<i64>(key_plus_100<i64>).skip(1).take(6).enumerate()
        var got: [i64]
        var front = true
        loop {
            var x? = if front => c.next() else => c.next_back()
            if !x? {
                break
            }

            got.push((unwrap!(x).0 as i64) * 1000 + unwrap!(x).1)
            front = !front
        }

        expect(ints_are(got, [101, 5106, 1102, 4105, 2103, 3104]), "map skip take enumerate from both ends")
        expect(c.remaining() == 0, "remaining after both ends")
    }

    expect_clean("both ends through a chain")
    CALLS = 0
}

fn deep_move_only() {
    reset()
    {
        var v = iter(Both<Counted>(10)).skip(2).take(6).enumerate().map<Counted>(drop_index<Counted>).filter(is_even<Counted>).collect<[Counted]>()
        expect(keys_are(v, [2, 4, 6]), "move-only four deep")
    }

    expect_clean("move-only four deep")
    CALLS = 0

    reset()
    {
        var v = iter(Both<Counted>(4)).zip(Both<Counted>(6)).rev().enumerate().collect<[(usize, (Counted, Counted))]>()
        expect(v.size() == 4 && v[0].0 == 0 && v[0].1.0.get() == 3 && v[3].1.1.get() == 0, "move-only pairs reversed")
    }

    expect_clean("move-only pairs reversed")

    reset()
    {
        var v = iter(Fwd<Counted>(3)).chain(Fwd<Counted>(3)).filter(is_odd<Counted>).collect<[Counted]>()
        expect(keys_are(v, [1, 1]), "move-only chain filter")
    }

    expect_clean("move-only chain filter")
    CALLS = 0
}

fn <E impl Elem> drop_index(p: (usize, E)) -> E {
    CALLS += 1
    return move(p.1)
}

fn abandoned_half_way() {
    reset()
    {
        var c = iter(Both<Counted>(10)).map<Counted>(same<Counted>).skip(1).take(6).enumerate()
        var a? = c.next()
        var b? = c.next_back()
        expect(a? && b?, "abandon map skip take enumerate")
    }

    expect_clean("abandoned map skip take enumerate")
    CALLS = 0

    reset()
    {
        var c = iter(Both<Counted>(5)).flat_map<Fwd<Counted>>(fwd_of<Counted, Counted>).filter(is_even<Counted>).peekable()
        var p? = c.peek()
        var a? = c.next()
        var q? = c.peek()
        expect(p? && a? && q?, "abandon flat_map filter peekable with an item held")
    }

    expect_clean("abandoned flat_map filter peekable")
    CALLS = 0

    reset()
    {
        var c = iter(Fwd<Counted>(4)).chain(Fwd<Counted>(4)).zip(Fwd<Counted>(9)).skip(3)
        var a? = c.next()
        var b? = c.next()
        expect(a? && b?, "abandon chain zip skip")
    }

    expect_clean("abandoned chain zip skip")

    reset()
    {
        var c = iter(Both<Counted>(8)).zip(Both<Counted>(8)).rev().step_by(3)
        var a? = c.next()
        expect(a?, "abandon zip rev step_by")
    }

    expect_clean("abandoned zip rev step_by")

    reset()
    {
        var c = iter(Fwd<Counted>(8)).take_while(below_5<Counted>).skip_while(below_3<Counted>).peekable()
        var a? = c.next()
        var p? = c.peek()
        expect(a? && p?, "abandon take_while skip_while peekable")
    }

    expect_clean("abandoned take_while skip_while peekable")
    CALLS = 0

    reset()
    {
        var c = iter(Both<Counted>(6)).filter(is_odd<Counted>).rev().enumerate()
        var a? = c.next()
        expect(a?, "abandon filter rev enumerate")
    }

    expect_clean("abandoned filter rev enumerate")
    CALLS = 0

    reset()
    {
        var c = iter(Both<Counted>(6)).skip(2).rev().take(2)
        expect(c.remaining() == 2, "never pulled")
    }

    expect_clean("chain built and dropped with nothing pulled")
}

fn gen_ints(n: i64) -> yield i64 {
    for var i: i64 = 0; i < n; i += 1 {
        yield i
    }
}

/// Holds a live item of its own across every yield.
fn gen_counted(n: i64) -> yield Counted {
    var kept = Counted(100)
    for var i: i64 = 0; i < n; i += 1 {
        yield Counted(i + kept.get() - 100)
    }
}

fn generators_through_adapters() {
    expect(ints_are(iter(gen_ints(10)).skip(2).step_by(3).collect<[i64]>(), [2, 5, 8]), "generator skip step_by")
    expect(ints_are(iter(gen_ints(10)).take_while(below_5<i64>).map<i64>(key_plus_100<i64>).collect<[i64]>(), [100, 101, 102, 103, 104]), "generator take_while map")
    expect(ints_are(iter(gen_ints(3)).chain(gen_ints(2)).collect<[i64]>(), [0, 1, 2, 0, 1]), "two generators chained")
    expect(ints_are(iter(gen_ints(3)).chain(gen_ints(0)).collect<[i64]>(), [0, 1, 2]), "generator chained with an empty one")
    expect(ints_are(iter(gen_ints(0)).chain(gen_ints(2)).collect<[i64]>(), [0, 1]), "empty generator chained with one")
    var v: [string] = ["a", "b", "c"]
    expect(iter(gen_ints(9)).zip(v.iter()).count() == 3, "generator zipped with a slice iterator")
    expect(iter(v.iter()).zip(gen_ints(2)).count() == 2, "slice iterator zipped with a generator")
    expect(iter(gen_ints(5)).enumerate().map<i64>(indexed<i64>).sum() == 10010, "generator enumerate map sum")
    expect(iter(gen_ints(4)).flat_map<Fwd<i64>>(fwd_of<i64, i64>).count() == 6, "generator flat_map")
    var p = iter(gen_ints(2)).peekable()
    var q? = p.peek()
    expect(q? && *unwrap!(q) == 0 && (p.next() ?? -1) == 0 && (p.next() ?? -1) == 1 && !p.peek()? && !p.next()?, "generator peekable")
    CALLS = 0

    reset()
    {
        var c = iter(gen_counted(6)).skip(1).take(3).enumerate().collect<[(usize, Counted)]>()
        expect(c.size() == 3 && c[0].1.get() == 1 && c[2].0 == 2, "generator of move-only items through a chain")
    }

    expect_clean("generator of move-only items collected")

    reset()
    {
        var c = iter(gen_counted(6)).filter(is_odd<Counted>).peekable()
        var p? = c.peek()
        expect(p?, "generator peek")
    }

    expect_clean("generator abandoned with a held item and a live local")
    CALLS = 0

    reset()
    {
        var c = iter(gen_counted(6)).chain(gen_counted(2)).take(8)
        expect(iter(gen_counted(3)).chain(gen_counted(3)).take(4).count() == 4, "generator chain take")
        var a? = c.next()
        expect(a?, "generator chain item")
    }

    expect_clean("generator chain abandoned")
}

fn main() -> i32 {
    building_pulls_nothing()
    deep_results()
    deep_pulls()
    both_ends_through_a_chain()
    deep_move_only()
    abandoned_half_way()
    generators_through_adapters()
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
