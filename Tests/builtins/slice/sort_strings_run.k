// sort, sort_unstable and sort_by on strings, at sizes 0..64 and around
// powers of two. Each string is a prefix of 1..12 letters from a three-letter
// alphabet (many duplicates and long shared prefixes), then `#` and the
// element's input index as four letters A..P, so every string is distinct
// and carries where it started. sort and sort_unstable must leave the strings
// in strictly increasing order and keep the multiset (a sum of hashes);
// sort_by, comparing only the first letter, must also keep the input order
// of strings with the same first letter.

import std::io

var FAILED: u64 = 0

fn fail(const what: string, n: usize) {
    if FAILED < 8 {
        io::println(f"FAIL {what} at n = {n}")
    }

    FAILED += 1
}

struct Rng {
    var s: u64
}

fn next(r: *Rng) -> u64 {
    var x = r->s
    x ^= x << 13
    x ^= x >> 7
    x ^= x << 17
    r->s = x
    return x
}

fn make(r: *Rng, index: usize) -> string {
    var buf: [u8; 17]
    var len = 1 + (next(r) % 12) as usize
    for var i: usize = 0; i < len; i += 1 {
        buf[i] = ('a' as u8) + (next(r) % 3) as u8
    }

    buf[len] = '#' as u8
    for var k: usize = 0; k < 4; k += 1 {
        buf[len + 1 + k] = ('A' as u8) + ((index >> (12 - 4 * k)) & 0xF) as u8
    }

    return string(&buf[0] as *const u8, len + 5)
}

fn hash(const s: string) -> u64 {
    var h: u64 = 1469598103934665603
    unsafe {
        var unsafe *p = s.data() as unsafe *const u8
        for var i: usize = 0; i < s.size(); i += 1 {
            h = (h ^ (p[i] as u64)) * 1099511628211
        }
    }

    return h
}

/// The input index stored after the `#`.
fn index_of(const s: string) -> usize {
    var n        = s.size()
    var v: usize = 0
    unsafe {
        var unsafe *p = s.data() as unsafe *const u8
        for var k: usize = 0; k < 4; k += 1 {
            v = (v << 4) | ((p[n - 4 + k] - ('A' as u8)) as usize)
        }
    }

    return v
}

fn first_byte(a: *const string, b: *const string) -> Ordering {
    unsafe {
        var x = (a->data() as unsafe *const u8)[0]
        var y = (b->data() as unsafe *const u8)[0]
        return x <=> y
    }
}

fn run(n: usize, mode: u32, r: *Rng) {
    var v       = Vector<string>()
    var sum: u64 = 0
    for var i: usize = 0; i < n; i += 1 {
        v.push(make(r, i))
        sum += hash(v[i])
    }

    var s: [string;] = v
    if mode == 0 {
        s.sort()
    } else if mode == 1 {
        s.sort_unstable()
    } else {
        s.sort_by(first_byte)
    }

    var got: u64 = 0
    for var i: usize = 0; i < n; i += 1 {
        got += hash(v[i])
        if i > 0 {
            if mode < 2 {
                if !((v[i - 1] <=> v[i]) == Ordering::Less) {
                    fail(f"order (mode {mode})", n)
                }
            } else {
                var o = first_byte(const &v[i - 1], const &v[i])
                if o == Ordering::Greater {
                    fail("order (sort_by)", n)
                } else if o == Ordering::Equal && index_of(v[i - 1]) > index_of(v[i]) {
                    fail("stability (sort_by)", n)
                }
            }
        }
    }

    if got != sum {
        fail(f"permutation (mode {mode})", n)
    }
}

fn main() -> i32 {
    var r: Rng
    r.s = 0x9E3779B97F4A7C15
    var cases: u64 = 0
    var n: usize   = 0
    while n <= 64 {
        for var mode: u32 = 0; mode < 3; mode += 1 {
            run(n, mode, &r)
            cases += 1
        }

        n += 1
    }

    for var lg: usize = 7; lg <= 15; lg += 1 {
        var m = (1 as usize) << lg
        for var d: usize = 0; d < 3; d += 1 {
            for var mode: u32 = 0; mode < 3; mode += 1 {
                run(m - 1 + d, mode, &r)
                cases += 1
            }
        }
    }

    io::println(f"strings {cases} failed {FAILED}")
    return (if FAILED == 0 => 0 else => 1)
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK: strings 276 failed 0
