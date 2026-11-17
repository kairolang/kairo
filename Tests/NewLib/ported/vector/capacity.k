// Capacity: size, is_empty, capacity, reserve, shrink_to_fit, resize(n) and
// resize(n, v), the growth steps a run of pushes takes for element sizes from
// 1 to 1025 bytes, and over-aligned elements across reserve and shrink.
//
// Cases from libc++ test/std/containers/sequences/vector/vector.capacity/
// Cases from Rust library/alloctests/tests/vec.rs
//
// differs from C++ and Rust: the first block a push allocates holds
// max(4, 64 / element size) elements and every later growth doubles
// (05-vector.md, Growth), so the capacities below are those, not 1 or 8.
// `reserve(n)` takes a total capacity as in C++, not an additional count as
// in Rust. Rust's `reserve_exact` and the exceptions-on-failure cases have no
// counterpart.

import self::Inputs::counted::*

@align(128)
struct Aligned128 {
    var k: i64
}

struct Block64 {
    var w: [i64; 8]
}

struct Block1025 {
    var b: [u8; 1025]
}

fn <E impl Elem> size_and_empty(const tag: string) {
    reset()
    {
        var v: [E]
        expect(v.size() == 0 && v.is_empty(), f"{tag}: empty")
        v.push(E::make(1))
        expect(v.size() == 1 && !v.is_empty(), f"{tag}: one")
        for var i: i64 = 0; i < 99; ++i {
            v.push(E::make(i))
        }

        expect(v.size() == 100, f"{tag}: size after 100 pushes")
        v.clear()
        expect(v.size() == 0 && v.is_empty(), f"{tag}: cleared")
        expect(v.capacity() >= 100, f"{tag}: clear keeps the capacity")
    }

    expect_clean(f"{tag}: size and empty")
}

fn <E impl Elem> reserve_cases(const tag: string) {
    reset()
    {
        var v: [E]
        v.reserve(0)
        expect(v.capacity() == 0, f"{tag}: reserve(0) on empty allocates nothing")
        v.reserve(2)
        expect(v.capacity() >= 2 && v.size() == 0, f"{tag}: reserve(2)")
        for var i: i64 = 0; i < 16; ++i {
            v.push(E::make(i))
        }

        expect(v.capacity() >= 16, f"{tag}: capacity covers 16 elements")
        var c = v.capacity()
        v.reserve(16)
        expect(v.capacity() == c, f"{tag}: reserving what fits does not reallocate")
        v.reserve(c + 1)
        expect(v.capacity() >= c + 1, f"{tag}: reserve past the capacity grows")
        expect(keys_are(v, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]), f"{tag}: reserve keeps the elements")
        c = v.capacity()
        var base = v.data()
        v.reserve(c)
        v.reserve(1)
        expect(v.capacity() == c && v.data() == base, f"{tag}: a smaller reserve is a no-op")
        for var i: usize = v.size(); i < c; ++i {
            v.push(E::make(i as i64))
        }

        expect(v.data() == base && v.capacity() == c, f"{tag}: pushing up to the capacity keeps the block")
        v.reserve(100000)
        expect(v.capacity() >= 100000 && v[0].key() == 0 && v[c - 1].key() == (c - 1) as i64, f"{tag}: large reserve keeps the elements")
    }

    expect_clean(f"{tag}: reserve")
}

fn <E impl Elem> shrink_cases(const tag: string) {
    reset()
    {
        var v: [E]
        v.shrink_to_fit()
        expect(v.capacity() == 0, f"{tag}: shrink of empty")
        for var i: i64 = 0; i < 10; ++i {
            v.push(E::make(i))
        }

        v.reserve(500)
        v.shrink_to_fit()
        expect(v.capacity() == 10 && v.size() == 10, f"{tag}: shrink_to_fit brings the capacity to the size")
        expect(keys_are(v, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]), f"{tag}: shrink keeps the elements")
        v.shrink_to_fit()
        expect(v.capacity() == 10, f"{tag}: shrinking twice")
        v.truncate(3)
        v.shrink_to_fit()
        expect(v.capacity() == 3 && keys_are(v, [0, 1, 2]), f"{tag}: shrink after truncate")
        v.truncate(1)
        v.shrink_to_fit()
        expect(v.capacity() == 1 && keys_are(v, [0]), f"{tag}: shrink to one")
        v.clear()
        v.shrink_to_fit()
        expect(v.capacity() == 0 && v.is_empty(), f"{tag}: shrink of a cleared vector gives the block back")
        v.push(E::make(42))
        expect(keys_are(v, [42]), f"{tag}: usable after shrinking to nothing")
    }

    expect_clean(f"{tag}: shrink_to_fit")
}

fn <E impl Elem> resize_default_cases(const tag: string, zero: i64) requires E impl Default {
    reset()
    {
        var v: [E]
        v.resize(0)
        expect(v.is_empty(), f"{tag}: resize(0) of empty")
        v.resize(4)
        expect(v.size() == 4 && v[0].key() == zero && v[3].key() == zero, f"{tag}: grow by default values")
        v[1] = E::make(9)
        v.resize(4)
        expect(v.size() == 4 && v[1].key() == 9, f"{tag}: resize to the same size changes nothing")
        v.resize(2)
        expect(v.size() == 2 && v[1].key() == 9, f"{tag}: shrink keeps the front")
        v.resize(70)
        expect(v.size() == 70 && v[1].key() == 9 && v[2].key() == zero && v[69].key() == zero, f"{tag}: grow past a reallocation")
        v.resize(0)
        expect(v.is_empty() && v.capacity() >= 70, f"{tag}: resize(0) keeps the capacity")
    }

    expect_clean(f"{tag}: resize")
}

fn <E impl Elem> resize_value_cases(const tag: string) requires E impl Copyable {
    reset()
    {
        var v: [E]
        v.resize(3, E::make(7))
        expect(keys_are(v, [7, 7, 7]), f"{tag}: resize(n, v) from empty")
        v.resize(5, E::make(8))
        expect(keys_are(v, [7, 7, 7, 8, 8]), f"{tag}: resize(n, v) appends copies")
        v.resize(2, E::make(9))
        expect(keys_are(v, [7, 7]), f"{tag}: resize(n, v) shrinks and ignores the value")
        v.resize(2, E::make(9))
        expect(keys_are(v, [7, 7]), f"{tag}: resize(n, v) to the same size")
        v.resize(0, E::make(1))
        expect(v.is_empty(), f"{tag}: resize(0, v)")
        v.push(E::make(5))
        v.push(E::make(6))
        v.resize(40, v[1].copy())
        expect(v.size() == 40 && v[39].key() == 6 && v[1].key() == 6 && v[0].key() == 5, f"{tag}: the value is an element, growth reallocates")
    }

    expect_clean(f"{tag}: resize with a value")
}

fn resize_counts() {
    reset()
    {
        var v: [Counted]
        v.resize(5, Counted(3))
        expect(LIVE == 5 && COPIES == 5, "resize copies the value into each new slot")
        var d = DTORS
        v.resize(2, Counted(0))
        expect(LIVE == 2 && DTORS - d >= 3, "shrinking by resize destroys the dropped elements")
        expect(LOGGED >= 3, "the dropped elements were destroyed live")
    }

    expect_clean("resize counts")
}

fn <E> expect_growth(const tag: string, make: fn() -> E) {
    var v: [E]
    var expected: usize = grown_cap<E>(1)
    var ok = true
    for var i: usize = 0; i < 300; ++i {
        v.push(make())
        if i + 1 > expected {
            expected = expected * 2
        }

        if v.capacity() != expected {
            ok = false
        }
    }

    expect(ok, f"{tag}: capacities follow max(4, 64 / size) then double")
}

fn mk_u8() -> u8 = 1
fn mk_u16() -> u16 = 1
fn mk_i32() -> i32 = 1
fn mk_i64() -> i64 = 1
fn mk_block64() -> Block64 {
    var b: Block64
    return b
}

fn mk_block1025() -> Block1025 {
    var b: Block1025
    return b
}

fn mk_string() -> string = "x"

fn growth_steps() {
    expect_growth<u8>("u8", mk_u8)
    expect_growth<u16>("u16", mk_u16)
    expect_growth<i32>("i32", mk_i32)
    expect_growth<i64>("i64", mk_i64)
    expect_growth<string>("string", mk_string)
    expect_growth<Block64>("64 bytes", mk_block64)
    expect_growth<Block1025>("1025 bytes", mk_block1025)
    var v: [u8]
    expect(v.capacity() == 0, "no allocation before the first push")
    v.push(1)
    expect(v.capacity() == 64, "the first block of bytes holds 64")
    var w: [Block1025]
    w.push(mk_block1025())
    expect(w.capacity() == 4, "the first block of a large element holds 4")
}

fn overaligned() {
    var v: [Aligned128]
    var ok = true
    var kept = true
    v.push(Aligned128 { k: 273 })
    for var i: usize = 0; i < 300; ++i {
        v.reserve(v.size() + i)
        if (&v[0] as usize) % 128 != 0 || v[0].k != 273 {
            ok = false
        }

        v.shrink_to_fit()
        if (&v[0] as usize) % 128 != 0 || v[0].k != 273 {
            kept = false
        }
    }

    expect(ok, "reserve keeps a 128-aligned element aligned")
    expect(kept, "shrink_to_fit keeps a 128-aligned element aligned")
    for var i: i64 = 0; i < 100; ++i {
        v.push(Aligned128 { k: i })
    }

    var all = true
    for var i: usize = 0; i < v.size(); ++i {
        if (&v[i] as usize) % 128 != 0 {
            all = false
        }
    }

    expect(all && v.size() == 101 && v[100].k == 99, "pushed 128-aligned elements stay aligned")
    v.clear()
    v.shrink_to_fit()
    expect(v.capacity() == 0, "shrink of an emptied over-aligned vector")
    v.push(Aligned128 { k: 5 })
    expect(v[0].k == 5 && (&v[0] as usize) % 128 == 0, "over-aligned vector is usable after shrinking to nothing")
}

fn main() -> i32 {
    size_and_empty<i32>("i32")
    size_and_empty<string>("string")
    size_and_empty<Counted>("Counted")
    size_and_empty<RCounted>("RCounted")
    reserve_cases<i32>("i32")
    reserve_cases<string>("string")
    reserve_cases<Counted>("Counted")
    reserve_cases<RCounted>("RCounted")
    shrink_cases<i32>("i32")
    shrink_cases<string>("string")
    shrink_cases<Counted>("Counted")
    shrink_cases<RCounted>("RCounted")
    resize_default_cases<i32>("i32", 0)
    resize_default_cases<string>("string", 0)
    resize_default_cases<Counted>("Counted", 0)
    resize_default_cases<RCounted>("RCounted", 0)
    resize_value_cases<i32>("i32")
    resize_value_cases<string>("string")
    resize_value_cases<Counted>("Counted")
    resize_value_cases<RCounted>("RCounted")
    resize_counts()
    growth_steps()
    overaligned()
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
