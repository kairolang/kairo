// sort, sort_unstable, sort_by and sort_by_key on ten input patterns
// (ascending, descending, all equal, sawtooth, organ pipe, random, random
// with 3 distinct values, random with 2 distinct values, ascending with one
// swap, sorted with a random tail) at lengths 0 to 40 and around powers of
// two up to 5000. Every result is sorted, is a permutation of the input and,
// for the stable sorts, keeps equal keys in input order. Elements are the
// integer types of every width, string and a move-only instrumented class
// (the live count returns to zero and no element is moved from a dead
// object). Sorting through sub-ranges and of reversed order by a
// comparator is covered too. Comparators that are not a total order are in
// sort_misuse.k.
//
// Cases from libc++ test/std/algorithms/alg.sorting/alg.sort/
// Cases from libc++ test/std/algorithms/alg.sorting/alg.stable.sort/ (stable_sort maps to sort)
// Cases from Rust library/alloctests/tests/sort/ (the pattern suite)
// Cases from Rust library/alloctests/tests/slice.rs (sort, sort_by_key, sort_unstable)

import self::inputs::inst::*
import std::io

eval PATTERNS: u32 = 10

/// Keys for `n` elements in pattern `pat`.
fn pattern_keys(n: usize, pat: u32, r: *Rng) -> [i64] {
    var k: [i64]
    for var i: usize = 0; i < n; ++i {
        var x: i64 = 0
        if pat == 0 {
            x = i as i64
        } else if pat == 1 {
            x = (n - i) as i64
        } else if pat == 2 {
            x = 7
        } else if pat == 3 {
            x = (i % 7) as i64
        } else if pat == 4 {
            x = (if i < n / 2 => i as i64 else => (n - i) as i64)
        } else if pat == 5 {
            x = rng_below(r, 1000000) as i64 - 500000
        } else if pat == 6 {
            x = rng_below(r, 3) as i64
        } else if pat == 7 {
            x = rng_below(r, 2) as i64 * 1000
        } else if pat == 8 {
            x = i as i64
        } else {
            x = (if i + 5 < n => i as i64 else => rng_below(r, 100000) as i64)
        }

        k.push(x)
    }

    if pat == 8 && n > 1 {
        var a = rng_below(r, n as u64) as usize
        var b = rng_below(r, n as u64) as usize
        var t = k[a]
        k[a] = k[b]
        k[b] = t
    }

    return k
}

/// The lengths run: 0..=40 and around powers of two.
fn next_len(n: usize) -> usize {
    if n < 40 {
        return n + 1
    }

    if n == 40 {
        return 63
    }

    if n == 63 {
        return 64
    }

    if n == 64 {
        return 65
    }

    if n == 65 {
        return 127
    }

    if n == 127 {
        return 128
    }

    if n == 128 {
        return 129
    }

    if n == 129 {
        return 255
    }

    if n == 255 {
        return 256
    }

    if n == 256 {
        return 257
    }

    if n == 257 {
        return 1000
    }

    if n == 1000 {
        return 1024
    }

    if n == 1024 {
        return 2049
    }

    if n == 2049 {
        return 5000
    }

    return 0
}

fn from_keys(const k: [i64]) -> [Inst] {
    var v: [Inst]
    for var i: usize = 0; i < k.size(); ++i {
        v.push(Inst(k[i], i as i64))
    }

    return v
}

/// Verifies that `v` is the sorted permutation of the `n` elements made from
/// `k`: sorted by key (descending when `desc`), every id present once, and
/// when `stable` equal keys in id order.
fn verify(const v: [Inst], const k: [i64], stable: bool, desc: bool, code: i32) {
    var n = k.size()
    if v.size() != n {
        fail("sort changes the length", code)
    }

    var seen: [bool]
    for var i: usize = 0; i < n; ++i {
        seen.push(false)
    }

    for var i: usize = 0; i < n; ++i {
        var id = v[i].id
        if id < 0 || id >= n as i64 || seen[id as usize] {
            fail("sort loses or duplicates an element", code + 1)
        }

        seen[id as usize] = true
        if v[i].key() != k[id as usize] {
            fail("sort separates a key from its element", code + 2)
        }

        if i > 0 {
            var a = v[i - 1].key()
            var b = v[i].key()
            if (if desc => a < b else => a > b) {
                fail("sort output is out of order", code + 3)
            }

            if stable && a == b && v[i - 1].id > v[i].id {
                fail("a stable sort reordered equal keys", code + 4)
            }
        }
    }
}

fn by_key_desc(a: *const Inst, b: *const Inst) -> Ordering {
    return a->key() <=> b->key()
}

fn by_key_reversed(a: *const Inst, b: *const Inst) -> Ordering {
    return b->key() <=> a->key()
}

fn neg_key_of(a: *const Inst) -> i64 {
    return 0 - a->key()
}

fn inst_patterns() {
    var r = rng_new(0xFEED)
    var n: usize = 0
    var sorts: i64 = 0
    loop {
        for var pat: u32 = 0; pat < PATTERNS; ++pat {
            var k = pattern_keys(n, pat, &r)
            {
                var v = from_keys(k)
                var s: [Inst;] = v
                s.sort()
                verify(v, k, true, false, 100)
            }

            {
                var v = from_keys(k)
                var s: [Inst;] = v
                s.sort_unstable()
                verify(v, k, false, false, 110)
            }

            {
                var v = from_keys(k)
                var s: [Inst;] = v
                s.sort_by(inst_by_key)
                verify(v, k, true, false, 120)
            }

            {
                var v = from_keys(k)
                var s: [Inst;] = v
                s.sort_by(by_key_reversed)
                verify(v, k, true, true, 130)
            }

            {
                var v = from_keys(k)
                var s: [Inst;] = v
                s.sort_by_key(inst_key_of)
                verify(v, k, true, false, 140)
            }

            {
                var v = from_keys(k)
                var s: [Inst;] = v
                s.sort_by_key(neg_key_of)
                verify(v, k, true, true, 150)
            }

            sorts += 6
        }

        n = next_len(n)
        if n == 0 {
            break
        }
    }

    check_clean("sort: instrumented", 160)
    check(sorts == 6 * 10 * 54, "every length and pattern ran", 161)
}

macro int_sorts!(FN, T) {
@no_warn(SC031W)
fn FN(const name: string, code: i32) {
    var r = rng_new(0xBEEF)
    var n: usize = 0
    loop {
        for var pat: u32 = 0; pat < PATTERNS; ++pat {
            var k = pattern_keys(n, pat, &r)
            var a: [T]
            var sum: u64 = 0
            for var i: usize = 0; i < n; ++i {
                var x = (k[i] * 40503 + 17) as T
                a.push(x)
                sum += x as u64
            }

            var b: [T] = a.copy()
            var s: [T;] = a
            s.sort()
            var t: [T;] = b
            t.sort_unstable()
            var sum2: u64 = 0
            for var i: usize = 0; i < n; ++i {
                sum2 += a[i] as u64
                if i > 0 && a[i] < a[i - 1] {
                    fail(f"{name} sort is out of order", code)
                }

                if a[i] != b[i] {
                    fail(f"{name} sort and sort_unstable differ", code + 1)
                }
            }

            if sum != sum2 {
                fail(f"{name} sort changes the multiset", code + 2)
            }

            if !s.is_sorted() || !t.is_sorted() {
                fail(f"{name} is_sorted disagrees after sort", code + 3)
            }
        }

        n = next_len(n)
        if n == 0 {
            break
        }
    }
}
}

int_sorts!(sort_i8, i8)
int_sorts!(sort_u8, u8)
int_sorts!(sort_i16, i16)
int_sorts!(sort_u16, u16)
int_sorts!(sort_i32, i32)
int_sorts!(sort_u32, u32)
int_sorts!(sort_i64, i64)
int_sorts!(sort_u64, u64)

fn int_extremes() {
    var a: [i32] = [i32::MAX, 0, i32::MIN, -1, 1, i32::MAX, i32::MIN]
    var s: [i32;] = a
    s.sort()
    check(a[0] == i32::MIN && a[1] == i32::MIN && a[2] == -1 && a[3] == 0 && a[4] == 1 && a[5] == i32::MAX && a[6] == i32::MAX, "i32 sort with the extremes", 170)
    var b: [i64] = [i64::MAX, i64::MIN, 0, -1, i64::MIN, i64::MAX]
    var t: [i64;] = b
    t.sort_unstable()
    check(b[0] == i64::MIN && b[1] == i64::MIN && b[2] == -1 && b[3] == 0 && b[5] == i64::MAX, "i64 sort_unstable with the extremes", 171)
    var c: [u64] = [u64::MAX, 0, 1, u64::MAX - 1, 0]
    var u: [u64;] = c
    u.sort()
    check(c[0] == 0 && c[1] == 0 && c[2] == 1 && c[3] == u64::MAX - 1 && c[4] == u64::MAX, "u64 sort with the extremes", 172)
    var d: [u8] = [255, 0, 128, 127, 255, 0]
    var w: [u8;] = d
    w.sort()
    check(d[0] == 0 && d[1] == 0 && d[2] == 127 && d[3] == 128 && d[4] == 255 && d[5] == 255, "u8 sort with the extremes", 173)
}

fn strings() {
    var r = rng_new(0x57A1)
    var n: usize = 0
    loop {
        for var pat: u32 = 0; pat < PATTERNS; ++pat {
            var k = pattern_keys(n, pat, &r)
            var a: [string]
            for var i: usize = 0; i < n; ++i {
                a.push(f"k{k[i] + 1000000}.{i}")
            }

            var b: [string] = a.copy()
            var s: [string;] = a
            s.sort()
            var t: [string;] = b
            t.sort_unstable()
            for var i: usize = 1; i < n; ++i {
                if a[i] < a[i - 1] || b[i] < b[i - 1] {
                    fail("string sort is out of order", 180)
                }
            }

            for var i: usize = 0; i < n; ++i {
                if a[i] != b[i] {
                    fail("string sort and sort_unstable differ", 181)
                }
            }
        }

        n = next_len(n)
        if n == 0 || n > 1100 {
            break
        }
    }

    var w: [string] = ["pear", "fig", "apple", "kiwi", "date", "banana", "cherry", "grape", "lime", "plum", "melon", "nut", "olive", "quince", "rasp", "straw", "tomato", "ugli", "vanilla", "walnut", "xigua", "yam", "zucchini"]
    var ws: [string;] = w
    ws.sort_by_key(string_len)
    var ok = true
    for var i: usize = 1; i < w.size(); ++i {
        ok = ok && w[i - 1].size() <= w[i].size()
    }

    check(ok, "string sort_by_key by length", 182)
    check(w[0] == "fig" && w[1] == "nut" && w[2] == "yam", "string sort_by_key keeps input order among equal keys", 183)
    ws.sort_by(string_reversed)
    check(w[0] == "zucchini" && w[22] == "apple", "string sort_by with a reversed comparator", 184)
    ws.sort()
    check(w[0] == "apple" && w[1] == "banana" && w[22] == "zucchini", "string sort", 185)
    var one: [string] = ["only"]
    var o: [string;] = one
    o.sort()
    o.sort_unstable()
    check(one[0] == "only", "string sort of one element", 186)
    var none: [string]
    var e: [string;] = none
    e.sort()
    e.sort_unstable()
    check(e.size() == 0, "string sort of empty", 187)
}

fn string_len(p: *const string) -> usize {
    return p->size()
}

fn string_reversed(a: *const string, b: *const string) -> Ordering {
    return *b <=> *a
}

fn sub_ranges() {
    var v: [i32] = [9, 8, 7, 6, 5, 4, 3, 2, 1, 0]
    var s: [i32;] = v
    s[2..7].sort()
    check(v[0] == 9 && v[1] == 8 && v[2] == 3 && v[6] == 7 && v[7] == 2 && v[9] == 0, "sort of a middle range leaves the rest", 190)
    s[..3].sort_unstable()
    check(v[0] == 3 && v[1] == 8 && v[2] == 9, "sort_unstable of a prefix", 191)
    s[7..].sort()
    check(v[7] == 0 && v[8] == 1 && v[9] == 2, "sort of a suffix", 192)
    s[4..5].sort()
    s[4..4].sort()
    s[10..].sort()
    check(v[4] == 5, "sort of one element and of empty ranges", 193)
    s.sort()
    check(s.is_sorted() && v[0] == 0 && v[9] == 9, "sort of the whole slice", 194)

    var iv = insts(10, 0, 1)
    var is: [Inst;] = iv
    is.sort_by(by_key_reversed)
    is[3..8].sort_by(inst_by_key)
    check(iv[2].key() == 7 && iv[3].key() == 2 && iv[7].key() == 6 && iv[8].key() == 1, "inst sort_by on a sub-range", 195)
    iv.clear()
    check_clean("sort: sub-ranges", 196)
}

fn main() -> i32 {
    inst_patterns()
    sort_i8("i8", 200)
    sort_u8("u8", 210)
    sort_i16("i16", 220)
    sort_u16("u16", 230)
    sort_i32("i32", 240)
    sort_u32("u32", 250)
    sort_i64("i64", 260)
    sort_u64("u64", 270)
    int_extremes()
    strings()
    sub_ranges()
    io::println("sort ok")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: sort ok
