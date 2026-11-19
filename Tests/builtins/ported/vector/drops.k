// Destruction and leak accounting: every object a vector holds is destroyed
// exactly once, by the operation that removes it or by the vector's own end,
// in the documented order, and a move leaves nothing behind that is
// destroyed twice. The checks use Counted (moved element by element) and
// RCounted (moved as bytes), which count live objects and log the id of each
// destroyed one in order.
//
// Cases from Rust library/alloctests/tests/vec.rs
//   (test_double_drop, test_vec_truncate_drop, test_drop of cleared, truncated
//   and removed elements, drop counting through growth)
// Cases from libc++ test/std/containers/sequences/vector/vector.modifiers/
//   (destroy_elements, clear, pop_back)
//
// differs from Rust: a vector destroys its elements from the last to the first,
// and `truncate` destroys the dropped tail from the last to the first
// (05-vector.md, truncate and op finally), where Rust drops front to back.
// A callback cannot unwind through a vector, so the cases where a Rust test
// panics in a predicate, a clone or a drop and checks the vector afterwards
// have no counterpart; the partial-operation states Kairo has (a drain dropped
// early, a retain or dedup that removed some) are covered where they arise.

import self::inputs::counted::*

/// Takes a vector and ends it.
fn <E impl Elem> consume(v: [E]) {
}

fn order_is(const want: [i64]) -> bool {
    if LOGGED != want.size() {
        return false
    }

    for var i: usize = 0; i < want.size(); ++i {
        if LOG[i] != want[i] {
            return false
        }
    }

    return true
}

fn <E impl Elem> two_vectors_one_ended_early(const tag: string) {
    reset()
    {
        var x = fill<E>(1)
        var y = fill<E>(1)
        consume<E>(move(x))
        expect(LIVE == 1, f"{tag}: ending one of two vectors leaves the other's element")
        expect(LOGGED == 1, f"{tag}: the ended vector destroyed its element once")
    }

    expect_clean(f"{tag}: two vectors")
    expect(LOGGED == 2, f"{tag}: each vector's element destroyed once in all")
}

fn <E impl Elem> truncate_destroys_the_tail(const tag: string) {
    reset()
    {
        var v = fill<E>(5)
        expect(LOGGED == 0, f"{tag}: building destroys nothing")
        v.truncate(3)
        expect(LOGGED == 2 && LIVE == 3, f"{tag}: truncate(3) of five destroys two")
        expect(LOG[0] == 4 && LOG[1] == 3, f"{tag}: the tail goes from the last to the first")
        v.truncate(3)
        v.truncate(9)
        expect(LOGGED == 2, f"{tag}: truncating to the size or past it destroys nothing")
        v.truncate(0)
        expect(LOGGED == 5 && LIVE == 0, f"{tag}: truncate(0) destroys the rest")
        expect(LOG[2] == 2 && LOG[3] == 1 && LOG[4] == 0, f"{tag}: the rest goes last to first")
    }

    expect_clean(f"{tag}: truncate")
    expect(LOGGED == 5, f"{tag}: the empty vector at the end destroys nothing more")
}

fn <E impl Elem> clear_destroys_everything(const tag: string) {
    reset()
    {
        var v = fill<E>(6)
        v.clear()
        expect(LOGGED == 6 && LIVE == 0, f"{tag}: clear destroys every element")
        expect(order_is([5, 4, 3, 2, 1, 0]), f"{tag}: clear goes last to first")
        v.clear()
        expect(LOGGED == 6, f"{tag}: clearing an empty vector destroys nothing")
        v.push(E::make(10))
        expect(LIVE == 1, f"{tag}: a push after clear makes one object")
    }

    expect_clean(f"{tag}: clear")
}

fn <E impl Elem> end_of_scope_order(const tag: string) {
    reset()
    {
        var v = fill<E>(40)
    }

    expect(LOGGED == 40 && LIVE == 0, f"{tag}: the vector destroys its 40 elements")
    var ok = true
    for var i: usize = 0; i < 40; ++i {
        if LOG[i] != 39 - i as i64 {
            ok = false
        }
    }

    expect(ok, f"{tag}: from the last to the first")
    expect_clean(f"{tag}: scope end")
}

fn <E impl Elem> removed_elements_end_with_their_binding(const tag: string) {
    reset()
    {
        var v = fill<E>(6)
        {
            var r = v.remove(2)
            expect(LOGGED == 0 && LIVE == 6, f"{tag}: a removed element is alive in its binding")
        }

        expect(LOGGED == 1 && LOG[0] == 2 && LIVE == 5, f"{tag}: destroyed when the binding ends")
        {
            var s = v.swap_remove(0)
        }

        expect(LOGGED == 2 && LOG[1] == 0 && LIVE == 4, f"{tag}: swap_remove the same")
        {
            var p? = v.pop()
            expect(p? && unwrap!(p).key() == 4, f"{tag}: popped the last")
        }

        expect(LOGGED == 3 && LOG[2] == 4 && LIVE == 3, f"{tag}: pop the same")
        v.clear()
        var q? = v.pop()
        expect(!q? && LOGGED == 6 && LIVE == 0, f"{tag}: clear destroys the rest, then there is nothing to pop")
    }

    expect_clean(f"{tag}: removed elements")
}

fn <E impl Elem> growth_leaks_nothing(const tag: string) {
    reset()
    {
        var bad = 0
        for var n: i64 = 0; n < 130; ++n {
            var v = fill<E>(n)
            if LIVE != n {
                bad += 1
            }

            var before = LOGGED
            v.clear()
            if LOGGED - before != n as usize {
                bad += 1
            }
        }

        expect(bad == 0, f"{tag}: for every length to 129 the live count is the length and clear destroys that many")
    }

    expect_clean(f"{tag}: growth leaks nothing")
}

fn <E impl Elem> assignment_destroys_the_old(const tag: string) {
    reset()
    {
        var v = fill<E>(5)
        v = fill<E>(2)
        expect(LOGGED == 5 && LIVE == 2, f"{tag}: assigning a vector destroys the old elements")
    }

    expect_clean(f"{tag}: assignment")
}

fn <E impl Elem> insert_remove_leaks_nothing(const tag: string) {
    reset()
    {
        var v: [E]
        for var round: i64 = 0; round < 50; ++round {
            v.insert(0, E::make(round))
            v.insert(v.size() / 2, E::make(round))
            v.push(E::make(round))
            if round % 3 == 0 {
                var r = v.remove(1)
            }

            if round % 4 == 0 {
                var s = v.swap_remove(0)
            }

            if round % 5 == 0 {
                var p? = v.pop()
            }
        }

        expect(LIVE == v.size() as i64, "live objects are exactly the elements held")
    }

    expect_clean(f"{tag}: insert and remove")
}

fn <E impl Elem> nested_vectors_destroy_inside_out(const tag: string) {
    reset()
    {
        var vv: [[E]]
        for var i: i64 = 0; i < 5; ++i {
            vv.push(fill<E>(3))
        }

        expect(LIVE == 15, f"{tag}: fifteen objects in five inner vectors")
        var inner = vv.remove(2)
        vv.truncate(2)
        expect(LIVE == 9, f"{tag}: truncating the outer vector destroys the inner ones")
    }

    expect_clean(f"{tag}: nested")
}

fn main() -> i32 {
    two_vectors_one_ended_early<Counted>("Counted")
    two_vectors_one_ended_early<RCounted>("RCounted")
    truncate_destroys_the_tail<Counted>("Counted")
    truncate_destroys_the_tail<RCounted>("RCounted")
    clear_destroys_everything<Counted>("Counted")
    clear_destroys_everything<RCounted>("RCounted")
    end_of_scope_order<Counted>("Counted")
    end_of_scope_order<RCounted>("RCounted")
    removed_elements_end_with_their_binding<Counted>("Counted")
    removed_elements_end_with_their_binding<RCounted>("RCounted")
    growth_leaks_nothing<Counted>("Counted")
    growth_leaks_nothing<RCounted>("RCounted")
    assignment_destroys_the_old<Counted>("Counted")
    assignment_destroys_the_old<RCounted>("RCounted")
    insert_remove_leaks_nothing<Counted>("Counted")
    insert_remove_leaks_nothing<RCounted>("RCounted")
    nested_vectors_destroy_inside_out<Counted>("Counted")
    nested_vectors_destroy_inside_out<RCounted>("RCounted")
    return finish()
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
