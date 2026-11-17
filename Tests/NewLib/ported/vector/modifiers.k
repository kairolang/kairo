// Modifiers: push, pop, insert at every position of every small size and at
// and around the capacity boundary, remove and swap_remove at every position,
// truncate, clear, and exchanging two vectors by moves, on i32, string and
// the counting classes. Counted and RCounted cases also check that elements
// move and are never copied, and that every object made is destroyed once.
//
// Cases from libc++ test/std/containers/sequences/vector/vector.modifiers/
// Cases from Rust library/alloctests/tests/vec.rs
//
// libc++'s emplace and emplace_back, range insertion and assignment and the
// exception-safety cases have no counterpart: a vector takes a built element.

import self::Inputs::counted::*

/// [0, n) with `x` placed at position `p`.
fn expected_with(n: i64, p: i64, x: i64) -> [i64] {
    var out: [i64]
    for var i: i64 = 0; i < p; ++i {
        out.push(i)
    }

    out.push(x)
    for var i: i64 = p; i < n; ++i {
        out.push(i)
    }

    return out
}

/// [0, n) without position `p`.
fn expected_without(n: i64, p: i64) -> [i64] {
    var out: [i64]
    for var i: i64 = 0; i < n; ++i {
        if i != p {
            out.push(i)
        }
    }

    return out
}

fn <E impl Elem> is_with(const v: [E], n: i64, p: i64, x: i64) -> bool {
    var want = expected_with(n, p, x)
    return keys_are(v, want)
}

fn <E impl Elem> is_without(const v: [E], n: i64, p: i64) -> bool {
    var want = expected_without(n, p)
    return keys_are(v, want)
}

fn <E impl Elem> push_and_pop(const tag: string) {
    reset()
    {
        var v: [E]
        for var i: i64 = 0; i < 200; ++i {
            v.push(E::make(i))
            if v.size() != (i + 1) as usize || v[v.size() - 1].key() != i {
                expect(false, f"{tag}: push {i}")
                break
            }
        }

        expect(is_without(v, 200, -1), f"{tag}: contents after 200 pushes")
        var order = true
        for var i: i64 = 199; i >= 0; --i {
            var p? = v.pop()
            if !p? || unwrap!(p).key() != i {
                order = false
            }
        }

        expect(order, f"{tag}: pop returns the last element each time")
        expect(v.is_empty() && v.capacity() >= 200, f"{tag}: pop keeps the capacity")
        var none? = v.pop()
        expect(!none?, f"{tag}: pop of empty is null")
        var again? = v.pop()
        expect(!again?, f"{tag}: pop of empty twice")
        v.push(E::make(1))
        var one? = v.pop()
        expect(one? && unwrap!(one).key() == 1 && v.is_empty(), f"{tag}: push then pop of one")
    }

    expect_clean(f"{tag}: push and pop")
}

fn <E impl Elem> push_copy_of_element(const tag: string) requires E impl Copyable {
    reset()
    {
        var v: [E]
        v.push(E::make(1))
        for var i: i64 = 0; i < 70; ++i {
            v.push(v[0].copy())
        }

        expect(v.size() == 71 && v[70].key() == 1 && v[35].key() == 1, f"{tag}: pushing a copy of an element across reallocations")
        var w = fill<E>(4)
        w.push(w[3].copy())
        w.push(w[0].copy())
        expect(keys_are(w, [0, 1, 2, 3, 3, 0]), f"{tag}: pushing copies of own elements")
    }

    expect_clean(f"{tag}: push of a copy")
}

fn <E impl Elem> insert_every_position(const tag: string, spare: usize) {
    reset()
    {
        var bad = 0
        for var n: i64 = 0; n <= 12; ++n {
            for var p: i64 = 0; p <= n; ++p {
                var v = Vector<E>::with_capacity(n as usize + spare)
                for var i: i64 = 0; i < n; ++i {
                    v.push(E::make(i))
                }

                v.insert(p as usize, E::make(100))
                if !is_with(v, n, p, 100) {
                    bad += 1
                }
            }
        }

        expect(bad == 0, f"{tag}: insert at every position, spare capacity {spare}")
    }

    expect_clean(f"{tag}: insert at every position, spare {spare}")
}

fn <E impl Elem> insert_at_capacity(const tag: string) {
    reset()
    {
        var v: [E]
        v.insert(0, E::make(0))
        expect(keys_are(v, [0]), f"{tag}: insert into empty")
        var n: i64 = 1
        for var round = 0; round < 6; ++round {
            while v.size() < v.capacity() {
                v.push(E::make(n))
                n += 1
            }

            var c = v.capacity()
            var mid = v.size() / 2
            v.insert(mid, E::make(-1))
            expect(v.capacity() > c && v.size() == c + 1, f"{tag}: insert into a full vector grows it")
            expect(v[mid].key() == -1 && v[0].key() == 0 && v[v.size() - 1].key() == n - 1, f"{tag}: insert into a full vector places the element")
            while v.size() < v.capacity() {
                v.push(E::make(n))
                n += 1
            }

            v.insert(v.size(), E::make(-2))
            expect(v[v.size() - 1].key() == -2, f"{tag}: insert at the end of a full vector")
            while v.size() < v.capacity() {
                v.push(E::make(n))
                n += 1
            }

            v.insert(0, E::make(-3))
            expect(v[0].key() == -3 && v[1].key() == 0, f"{tag}: insert at the front of a full vector")
            v.remove(0)
        }
    }

    expect_clean(f"{tag}: insert at capacity")
}

fn <E impl Elem> insert_copy_of_element(const tag: string) requires E impl Copyable {
    reset()
    {
        var v = fill<E>(5)
        v.insert(0, v[4].copy())
        v.insert(3, v[1].copy())
        v.insert(v.size(), v[0].copy())
        expect(keys_are(v, [4, 0, 1, 0, 2, 3, 4, 4]), f"{tag}: insert of copies of own elements")
        var full = Vector<E>::with_capacity(4)
        for var i: i64 = 0; i < 4; ++i {
            full.push(E::make(i))
        }

        full.insert(2, full[0].copy())
        expect(keys_are(full, [0, 1, 0, 2, 3]), f"{tag}: insert of an own element into a full vector")
    }

    expect_clean(f"{tag}: insert of a copy")
}

fn <E impl Elem> remove_every_position(const tag: string) {
    reset()
    {
        var bad = 0
        var badret = 0
        for var n: i64 = 1; n <= 12; ++n {
            for var p: i64 = 0; p < n; ++p {
                var v = fill<E>(n)
                var r = v.remove(p as usize)
                if r.key() != p {
                    badret += 1
                }

                if !is_without(v, n, p) {
                    bad += 1
                }
            }
        }

        expect(bad == 0, f"{tag}: remove at every position leaves the rest in order")
        expect(badret == 0, f"{tag}: remove returns the removed element")
    }

    expect_clean(f"{tag}: remove")
}

fn <E impl Elem> swap_remove_every_position(const tag: string) {
    reset()
    {
        var bad = 0
        var badret = 0
        for var n: i64 = 1; n <= 12; ++n {
            for var p: i64 = 0; p < n; ++p {
                var v = fill<E>(n)
                var r = v.swap_remove(p as usize)
                if r.key() != p {
                    badret += 1
                }

                // The last element fills the hole.
                var want = expected_without(n, n - 1)
                if p != n - 1 {
                    want[p as usize] = n - 1
                }

                if !keys_are(v, want) {
                    bad += 1
                }
            }
        }

        expect(bad == 0, f"{tag}: swap_remove puts the last element in the hole")
        expect(badret == 0, f"{tag}: swap_remove returns the removed element")
        var one = fill<E>(1)
        var only = one.swap_remove(0)
        expect(only.key() == 0 && one.is_empty(), f"{tag}: swap_remove of the only element")
    }

    expect_clean(f"{tag}: swap_remove")
}

fn <E impl Elem> truncate_and_clear(const tag: string) {
    reset()
    {
        var v = fill<E>(10)
        var c = v.capacity()
        v.truncate(20)
        expect(v.size() == 10, f"{tag}: truncate past the size changes nothing")
        v.truncate(10)
        expect(v.size() == 10, f"{tag}: truncate to the size changes nothing")
        v.truncate(4)
        expect(keys_are(v, [0, 1, 2, 3]) && v.capacity() == c, f"{tag}: truncate keeps the front and the block")
        v.truncate(0)
        expect(v.is_empty() && v.capacity() == c, f"{tag}: truncate(0)")
        v.truncate(0)
        v.clear()
        expect(v.is_empty(), f"{tag}: clear of empty")
        for var i: i64 = 0; i < 5; ++i {
            v.push(E::make(i))
        }

        v.clear()
        expect(v.is_empty() && v.capacity() == c, f"{tag}: clear keeps the block")
        v.push(E::make(8))
        expect(keys_are(v, [8]), f"{tag}: push after clear")
    }

    expect_clean(f"{tag}: truncate and clear")
}

fn <E impl Elem> exchange(const tag: string) {
    reset()
    {
        var a = fill<E>(3)
        var b = fill<E>(7)
        var pa = a.data()
        var pb = b.data()
        var t = move(a)
        a = move(b)
        b = move(t)
        expect(keys_are(a, [0, 1, 2, 3, 4, 5, 6]) && keys_are(b, [0, 1, 2]), f"{tag}: exchange by moves")
        expect(a.data() == pb && b.data() == pa, f"{tag}: exchange swaps the blocks")
        var e: [E]
        var t2 = move(e)
        e = move(a)
        a = move(t2)
        expect(a.is_empty() && e.size() == 7, f"{tag}: exchange with an empty vector")
    }

    expect_clean(f"{tag}: exchange")
}

fn element_moves() {
    reset()
    {
        var v: [Counted]
        for var i: i64 = 0; i < 20; ++i {
            v.push(Counted(i))
        }

        v.insert(0, Counted(100))
        var r = v.remove(5)
        var s = v.swap_remove(1)
        var p? = v.pop()
        expect(COPIES == 0, "push, insert, remove, swap_remove and pop never copy")
        expect(LIVE == 21 && ERRS == 0, "live objects after the operations")
        expect(r.key() == 4 && s.key() == 0, "removed values")
    }

    expect_clean("counted element moves")
    reset()
    {
        var v: [RCounted]
        for var i: i64 = 0; i < 20; ++i {
            v.push(RCounted(i))
        }

        v.insert(0, RCounted(100))
        var r = v.remove(5)
        expect(COPIES == 0 && r.key() == 4, "relocatable: no copy")
    }

    expect_clean("relocatable element moves")
}

fn main() -> i32 {
    push_and_pop<i32>("i32")
    push_and_pop<string>("string")
    push_and_pop<Counted>("Counted")
    push_and_pop<RCounted>("RCounted")
    push_copy_of_element<i32>("i32")
    push_copy_of_element<string>("string")
    push_copy_of_element<Counted>("Counted")
    push_copy_of_element<RCounted>("RCounted")
    insert_every_position<i32>("i32", 0)
    insert_every_position<i32>("i32", 1)
    insert_every_position<i32>("i32", 5)
    insert_every_position<string>("string", 0)
    insert_every_position<string>("string", 1)
    insert_every_position<string>("string", 5)
    insert_every_position<Counted>("Counted", 0)
    insert_every_position<Counted>("Counted", 1)
    insert_every_position<Counted>("Counted", 5)
    insert_every_position<RCounted>("RCounted", 0)
    insert_every_position<RCounted>("RCounted", 1)
    insert_every_position<RCounted>("RCounted", 5)
    insert_at_capacity<i32>("i32")
    insert_at_capacity<string>("string")
    insert_at_capacity<Counted>("Counted")
    insert_at_capacity<RCounted>("RCounted")
    insert_copy_of_element<i32>("i32")
    insert_copy_of_element<string>("string")
    insert_copy_of_element<Counted>("Counted")
    insert_copy_of_element<RCounted>("RCounted")
    remove_every_position<i32>("i32")
    remove_every_position<string>("string")
    remove_every_position<Counted>("Counted")
    remove_every_position<RCounted>("RCounted")
    swap_remove_every_position<i32>("i32")
    swap_remove_every_position<string>("string")
    swap_remove_every_position<Counted>("Counted")
    swap_remove_every_position<RCounted>("RCounted")
    truncate_and_clear<i32>("i32")
    truncate_and_clear<string>("string")
    truncate_and_clear<Counted>("Counted")
    truncate_and_clear<RCounted>("RCounted")
    exchange<i32>("i32")
    exchange<string>("string")
    exchange<Counted>("Counted")
    exchange<RCounted>("RCounted")
    element_moves()
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
