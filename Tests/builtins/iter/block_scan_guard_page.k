// A predicate that reads the element next to the one it is given is tested
// on the items a loop over them tests and on no other: a scan stops at the
// deciding element, so it never reads the element behind the slice's last
// one, nor, from the back, the one before its first. Safe code may step a
// pointer unchecked, so such a predicate compiles; the compiler does not
// vouch for it, and the scan keeps the loop over the items.
//
// The slice ends at an unreadable page, and for the scans from the back it
// starts right after one: a read outside it is a SIGSEGV. The lengths are
// one block, two and three behind the items tested one at a time, and the
// deciding element sits at every index that leaves it a neighbour. The mmap
// constants are the Linux values.
ffi "c" import "sys/mman.h"
import std::iter::*
import std::io

eval REGION: usize = 65536

var failed: i32 = 0

fn hold(const what: string, n: usize, at: usize, cond: bool) {
    if !cond {
        failed += 1
        if failed <= 20 {
            io::println(f"FAILED {what} n={n} at={at}")
        }
    }
}

/// Readable memory between two unreadable pages.
fn guarded() -> unsafe *u8 {
    unsafe {
        var unsafe *m = mmap(&null, 3 * REGION, 3, 0x22, -1, 0) as unsafe *u8
        if (m as usize) == usize::MAX {
            return &null
        }

        if mprotect(m as unsafe *void, REGION, 0) != 0 {
            return &null
        }

        if mprotect((m + 2 * REGION) as unsafe *void, REGION, 0) != 0 {
            return &null
        }

        return m + REGION
    }
}

fn pair_is_15(p: *const (*const i32)) -> bool = **p + *(*p + 1) == 15
fn pair_not_15(p: *const (*const i32)) -> bool = **p + *(*p + 1) != 15
fn back_pair_is_15(p: *const (*const i32)) -> bool = **p + *(*p - 1) == 15
fn back_pair_not_15(p: *const (*const i32)) -> bool = **p + *(*p - 1) != 15

/// 0 before the deciding element, 7 on it and 8 behind it: the pair that
/// starts on it is the first that makes 15.
fn value(i: usize, at: usize) -> i32 {
    if i < at {
        return 0
    }

    return if i == at => 7 else => 8
}

fn main() -> i32 {
    var unsafe *g = guarded()
    if g == &null {
        return 2
    }

    unsafe {
        for var n: usize = 40; n <= 104; n += 32 {
            // The slice that ends at the unreadable page, and the one that
            // starts at the first readable byte.
            var unsafe *hi = (g + REGION - n * 4) as unsafe *i32
            var unsafe *lo = g as unsafe *i32
            for var at: usize = 0; at + 1 < n; at += 1 {
                for var i: usize = 0; i < n; i += 1 {
                    hi[i]         = value(i, at)
                    lo[n - 1 - i] = value(i, at)
                }

                var f = Slice<const i32>(hi as unsafe *const i32, n)
                var b = Slice<const i32>(lo as unsafe *const i32, n)
                hold("position", n, at, (iter(f.iter()).position(pair_is_15) ?? n) == at)
                hold("find", n, at, *(iter(f.iter()).find(pair_is_15) ?? &f[0]) == 7)
                hold("any", n, at, iter(f.iter()).any(pair_is_15))
                hold("all", n, at, !iter(f.iter()).all(pair_not_15))
                hold("take_while", n, at, iter(f.iter()).take_while(pair_not_15).count() == at)
                hold("skip_while", n, at, iter(f.iter()).skip_while(pair_not_15).count() == n - at)
                hold("rev position", n, at, (iter(b.iter()).rev().position(back_pair_is_15) ?? n) == at)
                hold("rev find", n, at, *(iter(b.iter()).rev().find(back_pair_is_15) ?? &b[0]) == 7)
                hold("rev any", n, at, iter(b.iter()).rev().any(back_pair_is_15))
                hold("rev all", n, at, !iter(b.iter()).rev().all(back_pair_not_15))
                hold("rev take_while", n, at, iter(b.iter()).rev().take_while(back_pair_not_15).count() == at)
                hold("rev skip_while", n, at, iter(b.iter()).rev().skip_while(back_pair_not_15).count() == n - at)
            }
        }
    }

    if failed != 0 {
        return 1
    }

    io::println("ok")
    return 0
}

// --- lit wiring ---
// REQUIRES: host-linux
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.O2.exe %t.O3.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo -O2 %s -o %t.O2.exe --cache-dir %t.d/o2
// RUN: %t.O2.exe | %FileCheck %s
// RUN: %kairo -O3 %s -o %t.O3.exe --cache-dir %t.d/o3
// RUN: %t.O3.exe | %FileCheck %s
// CHECK: ok
