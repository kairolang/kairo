// XFAIL: *
//
// Compiler defect: a generic function cannot pass a `[E]` to a parameter of
// type `[const E;]`, which also rejects `a == b` between two `[E]` and
// `a.starts_with(a)`. The vector's `@implicit op as` conversion is found for a
// concrete element type (`Vector<i32>::from_slice(v)` compiles) but not when
// the element type is a template parameter: "no matching overload for call to
// 'from_slice'... cannot convert argument of type '[E]' to parameter 'items'
// of type '[const E;]'".
//
// Cases from libc++ test/std/containers/sequences/vector/vector.cons/
//   (construction from a whole sequence)

import self::Inputs::counted::*

fn <E impl Elem> from_whole(const tag: string) requires E impl Copyable {
    reset()
    {
        var src = fill<E>(5)
        var whole = Vector<E>::from_slice(src)
        expect(keys_are(whole, [0, 1, 2, 3, 4]), f"{tag}: from_slice of the whole vector")
        expect(keys_are(src, [0, 1, 2, 3, 4]), f"{tag}: from_slice leaves its source")
    }

    expect_clean(f"{tag}: from_slice")
}

fn <E impl Elem> extend_from_whole(const tag: string) requires E impl Copyable {
    reset()
    {
        var v = fill<E>(3)
        var w = fill<E>(2)
        v.extend_from(w)
        expect(keys_are(v, [0, 1, 2, 0, 1]), f"{tag}: extend_from another vector")
        var whole = fill<E>(3)
        whole.extend_from(whole)
        expect(keys_are(whole, [0, 1, 2, 0, 1, 2]), f"{tag}: extend_from the whole of itself")
        var grow = Vector<E>::with_capacity(4)
        for var i: i64 = 0; i < 4; ++i {
            grow.push(E::make(i))
        }

        grow.extend_from(grow)
        expect(keys_are(grow, [0, 1, 2, 3, 0, 1, 2, 3]), f"{tag}: the whole vector survives the reallocation")
    }

    expect_clean(f"{tag}: extend_from a whole vector")
}

fn <E impl Elem> compare_whole(const tag: string) requires E impl Eq {
    reset()
    {
        var a = fill<E>(5)
        var b = fill<E>(5)
        var c = fill<E>(4)
        expect(a == b && !(a != b), f"{tag}: equal vectors")
        expect(a != c && c != a, f"{tag}: a shorter vector is unequal")
        expect(a.starts_with(a) && a.ends_with(b), f"{tag}: a whole vector as a prefix and suffix")
    }

    expect_clean(f"{tag}: compare whole vectors")
}

fn main() -> i32 {
    from_whole<i32>("i32")
    from_whole<string>("string")
    from_whole<Counted>("Counted")
    from_whole<RCounted>("RCounted")
    extend_from_whole<i32>("i32")
    extend_from_whole<string>("string")
    extend_from_whole<Counted>("Counted")
    extend_from_whole<RCounted>("RCounted")
    compare_whole<i32>("i32")
    compare_whole<string>("string")
    compare_whole<Counted>("Counted")
    compare_whole<RCounted>("RCounted")
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
