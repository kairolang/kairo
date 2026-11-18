// Element access and comparison: indexing for read and write, first, last,
// get, at (negative from the end), data, begin and end, sub-ranges of every
// range form, iteration by value, by pointer and from the back, `==` and
// `!=` between vectors and slices, and the searching members reached through
// the slice view (contains, index_of, last_index_of, starts_with, ends_with).
//
// Cases from libc++ test/std/containers/sequences/vector/access.pass.cpp,
//   vector.data/, compare.pass.cpp, iterators.pass.cpp, contiguous.pass.cpp
// Cases from Rust library/alloctests/tests/vec.rs
//   (test_indexing, test_cmp, test_slice_to_mut, zero_sized_values counts)
//
// libc++'s ordering comparisons (`<`, `<=`, `>`, `>=`, `<=>`) between vectors,
// `at` throwing out_of_range, and the iterator-category cases have no
// counterpart: a vector compares with `==` and indexing traps (traps.k).

import self::inputs::counted::*

fn <E impl Elem> read_and_write(const tag: string) {
    reset()
    {
        var v = fill<E>(5)
        expect(v[0].key() == 0 && v[2].key() == 2 && v[4].key() == 4, f"{tag}: read by index")
        v[1] = E::make(11)
        v[4] = E::make(14)
        v[0] = E::make(10)
        expect(keys_are(v, [10, 11, 2, 3, 14]), f"{tag}: write by index")
        var cv: [const E;] = v
        expect(cv[1].key() == 11 && cv.size() == 5, f"{tag}: read through a const view")
        var one = fill<E>(1)
        one[0] = E::make(7)
        expect(keys_are(one, [7]), f"{tag}: write the only element")
    }

    expect_clean(f"{tag}: index")
}

fn <E impl Elem> first_last_get_at(const tag: string) {
    reset()
    {
        var e: [E]
        var ef? = e.first()
        var el? = e.last()
        var eg? = e.get(0)
        var ea? = e.at(0)
        var en? = e.at(-1)
        expect(!ef? && !el? && !eg? && !ea? && !en?, f"{tag}: every lookup on an empty vector is null")
        var v = fill<E>(5)
        var f? = v.first()
        var l? = v.last()
        expect(f? && l? && f->key() == 0 && l->key() == 4, f"{tag}: first and last")
        var g0? = v.get(0)
        var g4? = v.get(4)
        var g5? = v.get(5)
        var gm? = v.get(100000)
        expect(g0? && g4? && g0->key() == 0 && g4->key() == 4, f"{tag}: get in range")
        expect(!g5? && !gm?, f"{tag}: get out of range is null")
        var a0? = v.at(0)
        var am1? = v.at(-1)
        var am5? = v.at(-5)
        var am6? = v.at(-6)
        var a5? = v.at(5)
        expect(a0? && am1? && am5? && a0->key() == 0 && am1->key() == 4 && am5->key() == 0, f"{tag}: at counts back from the end")
        expect(!am6? && !a5?, f"{tag}: at out of range is null")
        var one = fill<E>(1)
        var of? = one.first()
        var ol? = one.last()
        var oa? = one.at(-1)
        expect(of? && ol? && oa? && of->key() == 0 && ol->key() == 0 && oa->key() == 0, f"{tag}: one element is first and last")
    }

    expect_clean(f"{tag}: first, last, get, at")
}

fn <E impl Elem> data_pointers(const tag: string) {
    reset()
    {
        var e: [E]
        var ed? = e.data()
        var eb? = e.begin()
        var ee? = e.end()
        expect(e.size() == 0, f"{tag}: empty has no elements")
        var v = fill<E>(4)
        var d? = v.data()
        var b? = v.begin()
        var n? = v.end()
        expect(d? && b? && n?, f"{tag}: data, begin and end of a non-empty vector")
        if d? && b? && n? {
            expect(d == b, f"{tag}: begin is data")
            expect(d->key() == 0, f"{tag}: data points at the first element")
            var span = unwrap!(n) as usize - unwrap!(d) as usize
            expect(span == 4 * sizeof E, f"{tag}: end is one past the last element")
        }

        var p1 = &v[1] as usize
        var p0 = &v[0] as usize
        expect(p1 - p0 == sizeof E, f"{tag}: elements are contiguous")
        var q = &v[3] as usize
        expect(q - p0 == 3 * sizeof E, f"{tag}: contiguous to the end")
        var dm? = v.data_mut()
        expect(dm?, f"{tag}: data_mut")
    }

    expect_clean(f"{tag}: data")
}

fn <E impl Elem> slice_keys(const s: [const E;], const want: [i64]) -> bool {
    if s.size() != want.size() {
        return false
    }

    for var i: usize = 0; i < s.size(); ++i {
        if s[i].key() != want[i] {
            return false
        }
    }

    return true
}

fn <E impl Elem> sub_ranges(const tag: string) {
    reset()
    {
        var v = fill<E>(6)
        var a: [i64] = [1, 2, 3]
        expect(slice_keys<E>(v[1..4], a), f"{tag}: a half-open range")
        var b: [i64] = [1, 2, 3, 4]
        expect(slice_keys<E>(v[1..=4], b), f"{tag}: an inclusive range")
        var c: [i64] = [0, 1, 2]
        expect(slice_keys<E>(v[..3], c), f"{tag}: up to a bound")
        var d: [i64] = [0, 1, 2, 3]
        expect(slice_keys<E>(v[..=3], d), f"{tag}: up to a bound, inclusive")
        var e: [i64] = [4, 5]
        expect(slice_keys<E>(v[4..], e), f"{tag}: from a bound")
        var f: [i64]
        expect(slice_keys<E>(v[6..], f), f"{tag}: from the end is empty")
        expect(slice_keys<E>(v[2..2], f), f"{tag}: an empty range")
        expect(slice_keys<E>(v[0..0], f), f"{tag}: an empty range at the front")
        expect(slice_keys<E>(v[6..6], f), f"{tag}: an empty range at the end")
        var g: [i64] = [0, 1, 2, 3, 4, 5]
        expect(slice_keys<E>(v[0..6], g), f"{tag}: the full range")
        expect(slice_keys<E>(v[..], g), f"{tag}: the open range")
        var w = v[2..5]
        w[0] = E::make(20)
        w[2] = E::make(40)
        var h: [i64] = [0, 1, 20, 3, 40, 5]
        expect(slice_keys<E>(v[0..6], h), f"{tag}: writing through a mutable sub-range")
    }

    expect_clean(f"{tag}: sub-ranges")
}

fn <E impl Elem> iteration(const tag: string) {
    reset()
    {
        var v = fill<E>(6)
        var sum: i64 = 0
        var n: i64 = 0
        for const *x in v {
            sum += x->key()
            n += 1
        }

        expect(sum == 15 && n == 6, f"{tag}: iterate by const pointer")
        for *x in v {
            *x = E::make(x->key() * 2)
        }

        expect(keys_are(v, [0, 2, 4, 6, 8, 10]), f"{tag}: write through the pointer binder")
        var e: [E]
        var none: i64 = 0
        for const *x in e {
            none += 1
        }

        expect(none == 0, f"{tag}: iterate an empty vector")
        var one = fill<E>(1)
        for *x in one {
            *x = E::make(9)
        }

        expect(keys_are(one, [9]), f"{tag}: iterate one element")
        var order = true
        var expect_key: i64 = 0
        for const *x in v {
            if x->key() != expect_key {
                order = false
            }

            expect_key += 2
        }

        expect(order, f"{tag}: front to back")
        var it = v.iter()
        var back: [i64]
        loop {
            var x? = it.next_back()
            if !x? {
                break
            }

            back.push(x->key())
        }

        expect(back.size() == 6 && back[0] == 10 && back[5] == 0, f"{tag}: from the back by next_back")
        var m = v.iter_mut()
        var mf? = m.next()
        expect(mf?, f"{tag}: iter_mut yields")
        if mf? {
            *mf = E::make(77)
        }

        expect(v[0].key() == 77, f"{tag}: iter_mut writes")
    }

    expect_clean(f"{tag}: iteration")
}

fn <E impl Elem> slice_comparison(const tag: string) requires E impl Eq {
    reset()
    {
        var a = fill<E>(5)
        var b = fill<E>(5)
        var c = fill<E>(4)
        expect(a[1..4] == b[1..4], f"{tag}: equal sub-ranges")
        expect(a[0..4] == c[0..4], f"{tag}: equal prefixes of different vectors")
        expect(!(a[1..3] == b[0..2]), f"{tag}: shifted sub-ranges differ")
        expect(a[0..5] != c[0..4] && c[0..4] != a[0..5], f"{tag}: slices of different lengths differ")
        expect(a[2..2] == c[0..0], f"{tag}: empty slices are equal")
        expect(a[0..5] == a[0..5], f"{tag}: a slice equals itself")
        b[4] = E::make(99)
        expect(a[0..5] != b[0..5] && a[0..4] == b[0..4], f"{tag}: one different element")
    }

    expect_clean(f"{tag}: slice comparison")
}

/// `==` and `!=` between two vectors, in functions that are not generic.
fn vector_comparison_integers() {
    var a: [i32] = [1, 2, 3, 4, 5]
    var b: [i32] = [1, 2, 3, 4, 5]
    var c: [i32] = [1, 2, 3, 4]
    var d: [i32] = [1, 2, 3, 4, 99]
    var e: [i32]
    var f: [i32]
    expect(a == b && !(a != b), "i32: equal vectors")
    expect(a != c && c != a, "i32: a shorter vector is unequal")
    expect(a != d, "i32: one different element")
    expect(e == f && e != a && a != e, "i32: empty vectors")
    expect(a == a, "i32: a vector equals itself")
    expect(a[0..4] == c, "i32: a sub-range equals a whole vector")
    expect(c == a[0..4], "i32: a whole vector equals a sub-range")
    d[4] = 5
    expect(a == d, "i32: equal once the element is restored")
}

fn vector_comparison_strings() {
    var a: [string] = ["x", "yy", ""]
    var b: [string] = ["x", "yy", ""]
    var c: [string] = ["x", "yy"]
    var d: [string] = ["x", "yy", "z"]
    var e: [string]
    expect(a == b && !(a != b), "string: equal vectors")
    expect(a != c && c != a && a != d && a != e, "string: unequal vectors")
    expect(e == e, "string: an empty vector equals itself")
}

fn <E impl Elem> searching(const tag: string) requires E impl Eq {
    reset()
    {
        var v: [E]
        for k in [5, 3, 5, 7, 3, 5] {
            v.push(E::make(k))
        }

        var last? = v.last_index_of(E::make(5))
        var lmiss? = v.last_index_of(E::make(4))
        var lseven? = v.last_index_of(E::make(7))
        var lthree? = v.last_index_of(E::make(3))
        expect(last? && unwrap!(last) == 5, f"{tag}: last_index_of the last match")
        expect(!lmiss?, f"{tag}: last_index_of no match is null")
        expect(lseven? && unwrap!(lseven) == 3 && lthree? && unwrap!(lthree) == 4, f"{tag}: last_index_of other values")
        var e: [E]
        var none? = e.last_index_of(E::make(1))
        expect(!none?, f"{tag}: last_index_of on empty")
        var pre = fill<E>(3)
        var all = fill<E>(5)
        expect(all.starts_with(pre[0..3]) && all.ends_with(all[2..5]), f"{tag}: starts_with and ends_with")
        expect(!all.starts_with(all[1..3]) && !all.ends_with(all[0..2]), f"{tag}: prefix and suffix that do not match")
        expect(all.starts_with(all[0..0]) && all.ends_with(all[5..5]), f"{tag}: the empty prefix and suffix")
        expect(all.starts_with(all[0..5]) && all.ends_with(all[0..5]), f"{tag}: the whole vector is its own prefix and suffix")
        expect(!pre.starts_with(all[0..5]), f"{tag}: a longer prefix does not match")
    }

    expect_clean(f"{tag}: searching")
}

/// contains and index_of on integers.
fn searching_integers() {
    var v: [i32] = [5, 3, 5, 7, 3, 5]
    expect(v.contains(7) && v.contains(5), "i32: contains a present value")
    expect(!v.contains(4), "i32: contains an absent value")
    var first? = v.index_of(5)
    var miss? = v.index_of(4)
    var seven? = v.index_of(7)
    expect(first? && unwrap!(first) == 0, "i32: index_of the first match")
    expect(!miss?, "i32: index_of no match is null")
    expect(seven? && unwrap!(seven) == 3, "i32: index_of a single match")
    var e: [i32]
    var none? = e.index_of(1)
    expect(!e.contains(1) && !none?, "i32: contains and index_of on empty")
    var big: [i32]
    for var i: i32 = 0; i < 100; ++i {
        big.push(i * 3)
    }

    var hit? = big.index_of(147)
    var miss2? = big.index_of(148)
    expect(hit? && unwrap!(hit) == 49 && !miss2? && big.contains(297) && !big.contains(298), "i32: a hundred elements, hit in the last block and misses")
}

fn main() -> i32 {
    read_and_write<i32>("i32")
    read_and_write<string>("string")
    read_and_write<Counted>("Counted")
    read_and_write<RCounted>("RCounted")
    first_last_get_at<i32>("i32")
    first_last_get_at<string>("string")
    first_last_get_at<Counted>("Counted")
    first_last_get_at<RCounted>("RCounted")
    data_pointers<i32>("i32")
    data_pointers<string>("string")
    data_pointers<Counted>("Counted")
    data_pointers<RCounted>("RCounted")
    sub_ranges<i32>("i32")
    sub_ranges<string>("string")
    sub_ranges<Counted>("Counted")
    sub_ranges<RCounted>("RCounted")
    iteration<i32>("i32")
    iteration<string>("string")
    iteration<Counted>("Counted")
    iteration<RCounted>("RCounted")
    slice_comparison<i32>("i32")
    slice_comparison<string>("string")
    slice_comparison<Counted>("Counted")
    slice_comparison<RCounted>("RCounted")
    searching<i32>("i32")
    searching<string>("string")
    searching<Counted>("Counted")
    searching<RCounted>("RCounted")
    searching_integers()
    vector_comparison_integers()
    vector_comparison_strings()
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
