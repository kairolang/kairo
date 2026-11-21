import builtin::base::alloc::*
import std::io::println
ffi "c" import "stdio.h"

eval MIB: usize = 1024 * 1024

// The process's resident pages: the second field of /proc/self/statm.
fn resident_pages() -> i64 {
    var buf: [u8; 256]
    var n: usize = 0
    unsafe {
        var unsafe *f = fopen("/proc/self/statm", "r")
        if f == &null { return -1 }
        n = fread(&buf[0] as unsafe *void, 1, 255, f)
        fclose(f)
    }
    var field = 0
    var v: i64 = 0
    for var i: usize = 0; i < n; i += 1 {
        if buf[i] == 32u8 { field += 1 }
        else if field == 1 { v = v * 10 + (buf[i] - 48u8) as i64 }
    }
    return v
}

fn touch(p: unsafe *u8, n: usize) { for var i: usize = 0; i < n; i += 4096 { unsafe { *(p + i) = 1 } } }

static keep: [usize; 100]

fn main() -> i32 {
    // Each round frees a written 3 MiB block, which the cache of freed
    // mappings keeps, then allocates a 128 KiB block (fresh or grown from
    // 4 KiB) that stays live.
    for var r: usize = 0; r < 100; r += 1 {
        var unsafe *big = alloc_raw(3 * MIB, 8)
        touch(big, 3 * MIB)
        free_raw(big, 3 * MIB, 8)
        var s: unsafe *u8 = &null
        if r % 2 == 0 {
            s = alloc_raw(131072, 8)
        } else {
            var n: usize = 4096
            s = alloc_raw(n, 8)
            while n < 131072 {
                s = resize_raw(s, n, n * 2, 8)
                n *= 2
            }
        }
        touch(s, 131072)
        unsafe { keep[r] = s as usize }
    }
    // 100 live blocks of 128 KiB are 12.5 MiB; a block holding the freed
    // 3 MiB mapping it took would make it 300 MiB.
    var mib = resident_pages() * 4096 / (MIB as i64)
    if mib < 100 { println("bounded") } else { println(f"resident {mib} MiB") }
    for var r: usize = 0; r < 100; r += 1 {
        var p: unsafe *u8 = &null
        unsafe { p = keep[r] as unsafe *u8 }
        free_raw(p, 131072, 8)
    }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// A short block never keeps a long freed mapping from the cache: one kept
// live after a 3 MiB block was freed holds about its own length, whether
// it is allocated at 128 KiB or grown to it.
// REQUIRES: clang, host-linux
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: bounded
