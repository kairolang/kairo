// sort and sort_unstable on primitive integers of every width, signed and
// unsigned, plus bool and char: these sort by radix above a size threshold
// (an LSD pass per byte for sort, an in-place MSD radix for sort_unstable)
// and by comparison below it. Keys cover the full range of the type,
// negatives included, in five patterns; every result must equal the merge
// sort through a callback on the same input.

import Inputs::slice_support::*
import std::io

fn <T impl Ord> by_ord(a: *const T, b: *const T) -> Ordering {
    return *a <=> *b
}

/// Bits for element `i` of `n` in pattern `pat`, before truncation to the
/// element's width.
fn bits(pat: u32, i: usize, n: usize, r: *Rng) -> u64 {
    if pat == 0 {
        return rng_next(r) // the full range
    }

    if pat == 1 {
        return rng_next(r) % 5 - 2 // few distinct, around zero
    }

    if pat == 2 {
        return 0x8000000000000000u64 // all equal: every digit pass is skipped
    }

    if pat == 3 {
        return i as u64 // ascending
    }

    return (n - i) as u64 * 0x0101010101010101u64 // descending, every byte set
}

fn <T impl Ord> one(n: usize, pat: u32, r: *Rng) -> u64 {
    var unsafe *a = raw_array<T>(n)
    var unsafe *b = raw_array<T>(n)
    var unsafe *c = raw_array<T>(n)
    var h: u64    = 0
    unsafe {
        var i: usize = 0
        while i < n {
            var x = bits(pat, i, n, r)
            eval if __builtin_is_same<T, bool>() {
                x &= 1
            }

            __builtin_copy((a + i) as unsafe *u8, &x as unsafe *const u8, sizeof T)
            i += 1
        }

        __builtin_copy(b as unsafe *u8, a as unsafe *const u8, n * sizeof T)
        __builtin_copy(c as unsafe *u8, a as unsafe *const u8, n * sizeof T)
        var sa = Slice<T>(a, n)
        var sb = Slice<T>(b, n)
        var sc = Slice<T>(c, n)
        sa.sort_by(by_ord<T>)
        sb.sort()
        sc.sort_unstable()
        if __builtin_compare_mem(a as unsafe *const u8, b as unsafe *const u8, n * sizeof T) != 0 {
            fail("sort differs from sort_by", n as u64, pat as u64)
        }

        if __builtin_compare_mem(a as unsafe *const u8, c as unsafe *const u8, n * sizeof T) != 0 {
            fail("sort_unstable differs from sort_by", n as u64, pat as u64)
        }

        i = 0
        while i < n {
            var x: u64 = 0
            __builtin_copy(&x as unsafe *u8, (a + i) as unsafe *const u8, sizeof T)
            h = fold(h, x)
            i += 1
        }
    }

    raw_array_free<T>(a, n)
    raw_array_free<T>(b, n)
    raw_array_free<T>(c, n)
    return h
}

fn <T impl Ord> all(const name: string) {
    var sizes: [usize; 12] = [0, 1, 2, 20, 127, 128, 255, 256, 257, 1000, 5003, 70000]
    var r                  = rng_make(0x51CE)
    var h: u64             = 0
    var s: usize           = 0
    while s < 12 {
        var pat: u32 = 0
        while pat < 5 {
            h = fold(h, one<T>(sizes[s], pat, &r))
            pat += 1
        }

        s += 1
    }

    io::println(f"{name} ok")
}

fn main() -> i32 {
    all<i8>("i8")
    all<u8>("u8")
    all<i16>("i16")
    all<u16>("u16")
    all<i32>("i32")
    all<u32>("u32")
    all<i64>("i64")
    all<u64>("u64")
    all<isize>("isize")
    all<usize>("usize")
    all<bool>("bool")
    all<char>("char")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK:      i8 ok
// CHECK-NEXT: u8 ok
// CHECK-NEXT: i16 ok
// CHECK-NEXT: u16 ok
// CHECK-NEXT: i32 ok
// CHECK-NEXT: u32 ok
// CHECK-NEXT: i64 ok
// CHECK-NEXT: u64 ok
// CHECK-NEXT: isize ok
// CHECK-NEXT: usize ok
// CHECK-NEXT: bool ok
// CHECK-NEXT: char ok
