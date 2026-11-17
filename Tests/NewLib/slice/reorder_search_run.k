// reverse, rotate and swap against direct models, on elements that move as
// bytes (i32, a 64-byte struct, which rotates by cycles) and on a move-only
// type that is not relocatable; binary_search and partition_point against a
// linear scan, with runs of equal keys; split_at_mut at every index.

import Inputs::slice_support::*
import std::io

fn <T impl Elem> test_reverse() -> u64 {
    var r        = rng_make(1)
    var n: usize = 0
    while n <= 70 {
        var unsafe *a = raw_array<T>(n)
        fill_pattern<T>(a, n, 0, &r)
        var s = Slice<T>(a, n)
        s.reverse()
        var i: usize = 0
        unsafe {
            while i < n {
                check(a[i].key() == (n - 1 - i) as u64, "reverse", n as u64, i as u64)
                i += 1
            }
        }

        destroy_all<T>(a, n)
        raw_array_free<T>(a, n)
        n += 1
    }

    return 71
}

fn <T impl Elem> rotate_case(n: usize, k: isize) {
    var r         = rng_make(1)
    var unsafe *a = raw_array<T>(n)
    fill_pattern<T>(a, n, 0, &r)
    var s = Slice<T>(a, n)
    s.rotate(k)
    if n > 0 {
        // k mod n, toward the left, without negating k.
        var m            = n as isize
        var left         = ((k % m) + m) % m
        var i:    usize  = 0
        unsafe {
            while i < n {
                check(a[i].key() == ((i + left as usize) % n) as u64, "rotate", n as u64, i as u64)
                i += 1
            }
        }
    }

    destroy_all<T>(a, n)
    raw_array_free<T>(a, n)
}

fn <T impl Elem> test_rotate() -> u64 {
    var cases: u64   = 0
    var n:     usize = 0
    while n <= 40 {
        var k: isize = 0 - 2 * (n as isize) - 1
        while k <= 2 * (n as isize) + 1 {
            rotate_case<T>(n, k)
            cases += 1
            k += 1
        }

        n += 1
    }

    rotate_case<T>(7, isize::MAX)
    rotate_case<T>(7, isize::MIN)
    rotate_case<T>(64, isize::MIN)
    rotate_case<T>(1, isize::MIN)
    return cases + 4
}

fn <T impl Elem> test_swap() -> u64 {
    var r            = rng_make(1)
    var cases: u64   = 0
    var n:     usize = 1
    while n <= 9 {
        var i: usize = 0
        while i < n {
            var j: usize = 0
            while j < n {
                var unsafe *a = raw_array<T>(n)
                fill_pattern<T>(a, n, 0, &r)
                var s = Slice<T>(a, n)
                s.swap(i, j)
                var x: usize = 0
                unsafe {
                    while x < n {
                        var want = (if x == i => j else if x == j => i else => x)
                        check(a[x].key() == want as u64, "swap", (i * 16 + j) as u64, x as u64)
                        x += 1
                    }
                }

                destroy_all<T>(a, n)
                raw_array_free<T>(a, n)
                cases += 1
                j += 1
            }

            i += 1
        }

        n += 1
    }

    return cases
}

fn test_binary_search() -> u64 {
    var cases: u64   = 0
    var n:     usize = 0
    while n <= 65 {
        var dup: usize = 1
        while dup <= 3 {
            var unsafe *a = raw_array<u64>(n)
            var unsafe *p = raw_array<S64>(n)
            var i: usize  = 0
            unsafe {
                while i < n {
                    a[i] = (2 * (i / dup) + 1) as u64
                    __builtin_construct_at<S64>((p + i) as unsafe *u8, S64::make(a[i], i as u64))
                    i += 1
                }
            }

            var sa = Slice<u64>(a, n)
            var sp = Slice<S64>(p, n)
            var v: u64 = 0
            while v <= (2 * n + 2) as u64 {
                var want: usize = 0
                unsafe {
                    while want < n && a[want] < v {
                        want += 1
                    }

                    var hit = want < n && a[want] == v
                    var got = sa.binary_search(v)
                    check(got.0 == hit && got.1 == want, "binary_search u64", n as u64, v)
                    var got2 = sp.binary_search(S64::make(v, 0))
                    check(got2.0 == hit && got2.1 == want, "binary_search s64", n as u64, v)
                }

                cases += 2
                v += 1
            }

            raw_array_free<u64>(a, n)
            raw_array_free<S64>(p, n)
            dup += 1
        }

        n += 1
    }

    return cases
}

static THRESHOLD: u64 = 0

fn below_threshold(a: *const u64) -> bool {
    return *a < THRESHOLD
}

fn test_partition_point() -> u64 {
    var cases: u64   = 0
    var n:     usize = 0
    while n <= 65 {
        var unsafe *a = raw_array<u64>(n)
        var i: usize  = 0
        unsafe {
            while i < n {
                a[i] = i as u64
                i += 1
            }
        }

        var s        = Slice<u64>(a, n)
        var t: usize = 0
        while t <= n {
            THRESHOLD = t as u64
            check(s.partition_point(below_threshold) == t, "partition_point", n as u64, t as u64)
            cases += 1
            t += 1
        }

        raw_array_free<u64>(a, n)
        n += 1
    }

    return cases
}

fn test_split_at_mut() -> u64 {
    var cases: u64    = 0
    var unsafe *a     = raw_array<u64>(9)
    var i:     usize  = 0
    unsafe {
        while i < 9 {
            a[i] = i as u64
            i += 1
        }
    }

    var s = Slice<u64>(a, 9)
    i = 0
    while i <= 9 {
        var (l, r) = s.split_at_mut(i)
        check(l.size() == i && r.size() == 9 - i, "split_at_mut sizes", i as u64, 0)
        if r.size() > 0 {
            r[0] += 100
            check(s[i] == (i + 100) as u64, "split_at_mut writes through", i as u64, 0)
            r[0] -= 100
        }

        cases += 1
        i += 1
    }

    raw_array_free<u64>(a, 9)
    return cases
}

fn main() -> i32 {
    io::println(f"reverse {test_reverse<i32>() + test_reverse<S64>() + test_reverse<Mo>()}")
    io::println(f"rotate {test_rotate<i32>() + test_rotate<S64>() + test_rotate<Mo>()}")
    io::println(f"swap {test_swap<i32>() + test_swap<S64>() + test_swap<Mo>()}")
    io::println(f"binary_search {test_binary_search()}")
    io::println(f"partition_point {test_partition_point()}")
    io::println(f"split_at_mut {test_split_at_mut()}")
    check(MO_OBJECTS == 0, "Mo objects leaked or destroyed twice", MO_OBJECTS as u64, 0)
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK:      reverse 213
// CHECK-NEXT: rotate 10221
// CHECK-NEXT: swap 855
// CHECK-NEXT: binary_search 26928
// CHECK-NEXT: partition_point 2211
// CHECK-NEXT: split_at_mut 10
