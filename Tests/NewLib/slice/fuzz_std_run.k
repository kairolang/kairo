// Differential fuzz against the C++ standard library: this program and
// Inputs/fuzz_std.cpp draw the same operations from the same seeded
// generator and apply them to the same array, the slice members here and
// std::reverse, std::rotate, std::swap, std::stable_sort, std::lower_bound,
// std::partition_point and std::find there. Elements are u64 ordered by
// their high half only, so a stable sort that reorders equal elements
// shows. A hash of the whole array (and of every search result) is printed
// every 4096 operations, and the two outputs must be equal. SEED and OPS
// pick the run; the seed is the first line, so a failure names it.

import std::io
ffi "c" import "stdlib.h"

struct Gen {
    var s: u64
}

fn next(g: *Gen) -> u64 {
    var x = g->s
    x ^= x >> 12
    x ^= x << 25
    x ^= x >> 27
    g->s = x
    return x * 0x2545F4914F6CDD1Du64
}

fn below(g: *Gen, n: u64) -> u64 {
    return next(g) % n
}

fn fold(h: u64, v: u64) -> u64 {
    return (h ^ v) * 0x100000001B3u64
}

fn by_high(a: *const u64, b: *const u64) -> Ordering {
    return (*a >> 32) <=> (*b >> 32)
}

fn high(a: *const u64) -> u64 {
    return *a >> 32
}

static THRESHOLD: u64 = 0

fn below_threshold(a: *const u64) -> bool {
    return (*a >> 32) < THRESHOLD
}

fn env_u64(const name: string, dflt: u64) -> u64 {
    unsafe {
        var unsafe *c = getenv(name.data() as unsafe *const u8 as unsafe *const __builtin_c_char)
        if c == &null {
            return dflt
        }

        return strtoull(c, &null, 10) as u64
    }
}

fn main() -> i32 {
    var seed = env_u64("SEED", 1)
    var ops  = env_u64("OPS", 20000)
    io::println(f"seed {seed}")
    var g          = Gen { s: seed * 0x9E3779B97F4A7C15u64 | 1 }
    var cap: usize = 3000
    var v: [u64]
    v.reserve(cap)
    var i: usize = 0
    while i < cap {
        v.push(next(&g) % 50 << 32 | (i as u64))
        i += 1
    }

    var all: [u64;] = v
    var h:   u64    = 0
    var step: u64     = 0
    while step < ops {
        var n  = below(&g, (cap + 1) as u64) as usize
        var lo = below(&g, (cap - n + 1) as u64) as usize
        var s  = all[lo..lo + n]
        var k  = below(&g, 9)
        if k == 0 {
            s.reverse()
        } else if k == 1 {
            var r = (below(&g, (2 * n + 3) as u64) as isize) - (n as isize) - 1
            s.rotate(r)
        } else if k == 2 && n > 0 {
            s.swap(below(&g, n as u64) as usize, below(&g, n as u64) as usize)
        } else if k == 3 {
            s.sort_by(by_high)
        } else if k == 4 {
            s.sort_by_key(high)
        } else if k == 5 {
            s.sort_by(by_high)
            var x = below(&g, 52) << 32
            THRESHOLD = x >> 32
            h = fold(h, s.partition_point(below_threshold) as u64)
        } else if k == 6 && n > 0 {
            var x? = s.index_of(s[below(&g, n as u64) as usize])
            h = fold(h, (x ?? 99999) as u64)
        } else if k == 7 {
            var (a, b) = s.split_at(below(&g, (n + 1) as u64) as usize)
            h = fold(h, (a.size() * 7 + b.size()) as u64)
        } else {
            var m = all.size()
            var t = all[0..m]
            t.reverse()
        }

        step += 1
        if step % 4096 == 0 || step == ops {
            var j: usize = 0
            while j < cap {
                h = fold(h, all[j])
                j += 1
            }

            io::println(f"{step} {h}")
        }
    }

    return 0
}

// --- lit wiring ---
// REQUIRES: newlib, clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo_new %s -O2 -o %t.d/k.exe --cache-dir %t.d/c
// RUN: %clangxx -O2 -std=c++20 %S/Inputs/fuzz_std.cpp -o %t.d/c.exe
// RUN: env SEED=1 %t.d/k.exe > %t.d/k1.txt
// RUN: env SEED=1 %t.d/c.exe > %t.d/c1.txt
// RUN: diff %t.d/k1.txt %t.d/c1.txt
// RUN: env SEED=7 OPS=50000 %t.d/k.exe > %t.d/k7.txt
// RUN: env SEED=7 OPS=50000 %t.d/c.exe > %t.d/c7.txt
// RUN: diff %t.d/k7.txt %t.d/c7.txt
