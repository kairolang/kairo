// retain (the library's erase_if): removing none, all, the first, the last,
// alternating elements and every element but one, the order in which the
// predicate sees the elements, and erasing every element equal to a value;
// dedup on tables of runs and on every element type that has `==`. Counted
// and RCounted cases check that a removed element is destroyed once, a kept
// one is moved and not copied, and a duplicate is destroyed and the first of
// its run kept.
//
// Cases from libc++ test/std/containers/sequences/vector/vector.erasure/
// Cases from Rust library/alloctests/tests/vec.rs
//
// libc++'s `erase(v, value)` has no member of its own: it is `retain` with a
// predicate on the value. Rust's `dedup_by` and `dedup_by_key`, `retain_mut`
// and the panicking-predicate cases have no counterpart.

import self::inputs::counted::*

static NEXT: i64 = 0
static ORDERED: bool = true
static VISITS: i64 = 0
static ERASE_KEY: i64 = 0

fn <E impl Elem> keep_all(p: *const E) -> bool {
    return true
}

fn <E impl Elem> keep_none(p: *const E) -> bool {
    return false
}

fn <E impl Elem> keep_even(p: *const E) -> bool {
    return p->key() % 2 == 0
}

fn <E impl Elem> keep_odd(p: *const E) -> bool {
    return p->key() % 2 != 0
}

fn <E impl Elem> keep_not_first(p: *const E) -> bool {
    return p->key() != 0
}

fn <E impl Elem> keep_not_nine(p: *const E) -> bool {
    return p->key() != 9
}

fn <E impl Elem> keep_only_five(p: *const E) -> bool {
    return p->key() == 5
}

fn <E impl Elem> keep_in_order_true(p: *const E) -> bool {
    if p->key() != NEXT {
        ORDERED = false
    }

    NEXT += 1
    VISITS += 1
    return true
}

fn <E impl Elem> keep_in_order_false(p: *const E) -> bool {
    if p->key() != NEXT {
        ORDERED = false
    }

    NEXT += 1
    VISITS += 1
    return false
}

fn <E impl Elem> keep_not_key(p: *const E) -> bool {
    return p->key() != ERASE_KEY
}

fn <E impl Elem> retain_cases(const tag: string) {
    reset()
    {
        var v = fill<E>(10)
        v.retain(keep_all<E>)
        expect(keys_are(v, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]), f"{tag}: keep all")
        v.retain(keep_even<E>)
        expect(keys_are(v, [0, 2, 4, 6, 8]), f"{tag}: keep the even ones")
        v.retain(keep_odd<E>)
        expect(v.is_empty(), f"{tag}: keep the odd ones of five even ones")
        v.retain(keep_all<E>)
        v.retain(keep_none<E>)
        expect(v.is_empty(), f"{tag}: retain on empty")
        var cap = Vector<E>::with_capacity(20)
        cap.retain(keep_none<E>)
        expect(cap.capacity() >= 20, f"{tag}: retain keeps the block")
        var a = fill<E>(10)
        a.retain(keep_none<E>)
        expect(a.is_empty() && a.capacity() >= 10, f"{tag}: keep none empties the vector and keeps the block")
        var b = fill<E>(10)
        b.retain(keep_not_first<E>)
        expect(keys_are(b, [1, 2, 3, 4, 5, 6, 7, 8, 9]), f"{tag}: remove the first")
        var c = fill<E>(10)
        c.retain(keep_not_nine<E>)
        expect(keys_are(c, [0, 1, 2, 3, 4, 5, 6, 7, 8]), f"{tag}: remove the last")
        var d = fill<E>(10)
        d.retain(keep_only_five<E>)
        expect(keys_are(d, [5]), f"{tag}: keep one")
        var e = fill<E>(1)
        e.retain(keep_all<E>)
        expect(keys_are(e, [0]), f"{tag}: one kept")
        e.retain(keep_none<E>)
        expect(e.is_empty(), f"{tag}: one removed")
        var f = fill<E>(100)
        f.retain(keep_odd<E>)
        expect(f.size() == 50 && f[0].key() == 1 && f[49].key() == 99, f"{tag}: half of a hundred")
    }

    expect_clean(f"{tag}: retain")
}

fn <E impl Elem> retain_order(const tag: string) {
    reset()
    {
        NEXT = 0
        ORDERED = true
        VISITS = 0
        var v = fill<E>(40)
        v.retain(keep_in_order_true<E>)
        expect(ORDERED && VISITS == 40 && v.size() == 40, f"{tag}: the predicate sees each element once, front to back, keeping all")
        NEXT = 0
        ORDERED = true
        VISITS = 0
        v.retain(keep_in_order_false<E>)
        expect(ORDERED && VISITS == 40 && v.is_empty(), f"{tag}: the predicate sees each element once, front to back, removing all")
        NEXT = 0
        VISITS = 0
        v.retain(keep_in_order_true<E>)
        expect(VISITS == 0, f"{tag}: the predicate is not called on an empty vector")
    }

    expect_clean(f"{tag}: retain order")
}

fn <E impl Elem> erase_value(const tag: string) {
    reset()
    {
        var v: [E]
        for k in [1, 2, 3, 1, 4, 1, 1, 5, 1] {
            v.push(E::make(k))
        }

        ERASE_KEY = 1
        var before = v.size()
        v.retain(keep_not_key<E>)
        expect(keys_are(v, [2, 3, 4, 5]) && before - v.size() == 5, f"{tag}: erase every element equal to a value")
        ERASE_KEY = 7
        v.retain(keep_not_key<E>)
        expect(keys_are(v, [2, 3, 4, 5]), f"{tag}: erase of a value that is not there")
        ERASE_KEY = 2
        v.retain(keep_not_key<E>)
        ERASE_KEY = 5
        v.retain(keep_not_key<E>)
        expect(keys_are(v, [3, 4]), f"{tag}: erase at both ends")
    }

    expect_clean(f"{tag}: erase value")
}

fn retain_counts() {
    reset()
    {
        var v = fill<Counted>(20)
        v.retain(keep_even<Counted>)
        expect(LOGGED == 10, "retain destroys each removed element once")
        var odd = true
        for var i: usize = 0; i < LOGGED; ++i {
            if LOG[i] % 2 == 0 {
                odd = false
            }
        }

        expect(odd, "the destroyed elements are the odd ones")
        expect(LIVE == 10 && COPIES == 0, "the kept elements are moved, not copied")
    }

    expect_clean("retain counts, Counted")
    reset()
    {
        var v = fill<RCounted>(20)
        v.retain(keep_not_first<RCounted>)
        expect(LOGGED == 1 && LOG[0] == 0 && LIVE == 19 && COPIES == 0, "retain removing the first of relocatable elements")
    }

    expect_clean("retain counts, RCounted")
}

fn <E impl Elem> run_of(const keys: [i64], const want: [i64], const tag: string) requires E impl Eq {
    reset()
    {
        var v: [E]
        for var i: usize = 0; i < keys.size(); ++i {
            v.push(E::make(keys[i]))
        }

        v.dedup()
        expect(keys_are(v, want), f"{tag}: dedup")
    }

    expect_clean(f"{tag}: dedup run")
}

fn <E impl Elem> dedup_table(const tag: string) requires E impl Eq {
    var k0: [i64] = []
    var w0: [i64] = []
    run_of<E>(k0, w0, f"{tag} []")
    var k1: [i64] = [1]
    var w1: [i64] = [1]
    run_of<E>(k1, w1, f"{tag} [1]")
    var k2: [i64] = [1, 1]
    var w2: [i64] = [1]
    run_of<E>(k2, w2, f"{tag} [1 1]")
    var k3: [i64] = [1, 2, 3]
    var w3: [i64] = [1, 2, 3]
    run_of<E>(k3, w3, f"{tag} [1 2 3]")
    var k4: [i64] = [1, 1, 2, 3]
    var w4: [i64] = [1, 2, 3]
    run_of<E>(k4, w4, f"{tag} [1 1 2 3]")
    var k5: [i64] = [1, 2, 2, 3]
    var w5: [i64] = [1, 2, 3]
    run_of<E>(k5, w5, f"{tag} [1 2 2 3]")
    var k6: [i64] = [1, 2, 3, 3]
    var w6: [i64] = [1, 2, 3]
    run_of<E>(k6, w6, f"{tag} [1 2 3 3]")
    var k7: [i64] = [1, 1, 2, 2, 2, 3, 3]
    var w7: [i64] = [1, 2, 3]
    run_of<E>(k7, w7, f"{tag} runs")
    var k8: [i64] = [12, 12, 12, 12, 12, 11, 11, 11, 11, 11, 11]
    var w8: [i64] = [12, 11]
    run_of<E>(k8, w8, f"{tag} two long runs")
    var k9: [i64] = [1, 2, 1, 2, 1]
    var w9: [i64] = [1, 2, 1, 2, 1]
    run_of<E>(k9, w9, f"{tag} alternating")
    var k10: [i64] = [5, 5, 5, 5]
    var w10: [i64] = [5]
    run_of<E>(k10, w10, f"{tag} all equal")
    var k11: [i64] = [1, 1, 2, 1, 1]
    var w11: [i64] = [1, 2, 1]
    run_of<E>(k11, w11, f"{tag} equal values apart")
}

fn <E impl Elem> dedup_every_bit_pattern(const tag: string) requires E impl Eq {
    reset()
    {
        var bad = 0
        for var x: i64 = 0; x < 255; ++x {
            var v: [E]
            var want: [i64]
            for var bit: i64 = 0; bit < 8; ++bit {
                var b = (x >> bit) & 1
                v.push(E::make(b))
                if want.is_empty() || want[want.size() - 1] != b {
                    want.push(b)
                }
            }

            v.dedup()
            if !keys_are(v, want) {
                bad += 1
            }
        }

        expect(bad == 0, f"{tag}: dedup of every run structure of eight bits")
    }

    expect_clean(f"{tag}: dedup bit patterns")
}

fn dedup_counts() {
    reset()
    {
        var v: [Counted]
        for k in [1, 1, 2, 3, 3, 3, 1] {
            v.push(Counted(k))
        }

        v.dedup()
        expect(LOGGED == 3 && LIVE == 4 && COPIES == 0, "dedup destroys each duplicate and copies nothing")
        var s: [string] = ["a", "a", "b", "b", "a"]
        s.dedup()
        expect(s.size() == 3 && s[0] == "a" && s[1] == "b" && s[2] == "a", "dedup of strings")
    }

    expect_clean("dedup counts")
}

fn main() -> i32 {
    retain_cases<i32>("i32")
    retain_cases<string>("string")
    retain_cases<Counted>("Counted")
    retain_cases<RCounted>("RCounted")
    retain_order<i32>("i32")
    retain_order<string>("string")
    retain_order<Counted>("Counted")
    retain_order<RCounted>("RCounted")
    erase_value<i32>("i32")
    erase_value<string>("string")
    erase_value<Counted>("Counted")
    erase_value<RCounted>("RCounted")
    retain_counts()
    dedup_table<i32>("i32")
    dedup_table<string>("string")
    dedup_table<Counted>("Counted")
    dedup_table<RCounted>("RCounted")
    dedup_every_bit_pattern<i32>("i32")
    dedup_every_bit_pattern<string>("string")
    dedup_every_bit_pattern<Counted>("Counted")
    dedup_every_bit_pattern<RCounted>("RCounted")
    dedup_counts()
    return finish()
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
