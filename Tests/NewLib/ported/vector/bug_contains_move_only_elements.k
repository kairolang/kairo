// XFAIL: *
//
// Library or compiler defect: `contains` and `index_of` (and so `op in`) on
// a vector of elements that are not integers fail to instantiate: "cannot
// copy a value of type 'string' in 'slice_find<string>': '*v' is const, so
// the transfer cannot move it", pointing at `var x = *v` in the
// integer-only branch of `slice_find` (containers/slice.k) that an `eval if`
// should have discarded for a `string`. `last_index_of`, `starts_with` and
// `ends_with` on the same vectors compile.
//
// Cases from libc++ test/std/containers/sequences/vector/vector.erasure/
//   (finding values among non-trivial elements)

import self::Inputs::counted::*

fn <E impl Elem> find_values(const tag: string) requires E impl Eq {
    reset()
    {
        var v: [E]
        for k in [5, 3, 5, 7, 3, 5] {
            v.push(E::make(k))
        }

        expect(v.contains(E::make(7)) && v.contains(E::make(5)), f"{tag}: contains a present value")
        expect(!v.contains(E::make(4)), f"{tag}: contains an absent value")
        var first? = v.index_of(E::make(5))
        var miss? = v.index_of(E::make(4))
        var seven? = v.index_of(E::make(7))
        expect(first? && unwrap!(first) == 0, f"{tag}: index_of the first match")
        expect(!miss?, f"{tag}: index_of no match is null")
        expect(seven? && unwrap!(seven) == 3, f"{tag}: index_of a single match")
        var e: [E]
        var none? = e.index_of(E::make(1))
        expect(!e.contains(E::make(1)) && !none?, f"{tag}: contains and index_of on empty")
    }

    expect_clean(f"{tag}: find values")
}

fn main() -> i32 {
    find_values<string>("string")
    find_values<Counted>("Counted")
    find_values<RCounted>("RCounted")
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
