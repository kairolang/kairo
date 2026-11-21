import builtin::base::alloc::*
import std::io::println
ffi "c" import "stdio.h"

eval MIB: usize = 1024 * 1024

// The process's minor page faults: field 10 of /proc/self/stat, the eighth
// after the ')' that ends the command name.
fn minor_faults() -> i64 {
    var buf: [u8; 1024]
    var n: usize = 0
    unsafe {
        var unsafe *f = fopen("/proc/self/stat", "r")
        if f == &null { return -1 }
        n = fread(&buf[0] as unsafe *void, 1, 1023, f)
        fclose(f)
    }
    var i = n
    while i > 0 && buf[i - 1] != 41u8 { i -= 1 }
    var field = 0
    var v: i64 = 0
    while i < n {
        if buf[i] == 32u8 { field += 1 }
        else if field == 8 { v = v * 10 + (buf[i] - 48u8) as i64 }
        i += 1
    }
    return v
}

// One block grown 4 KiB -> 2 MiB with every page written, then freed: the
// cache of freed mappings always has room for it.
fn round() -> usize {
    var        n  = 4096 as usize
    var unsafe *p = alloc_raw(n, 8)
    unsafe { *p = 1 }
    while n < 2 * MIB {
        p = resize_raw(p, n, n * 2, 8)
        for var i = n; i < n * 2; i += 4096 { unsafe { *(p + i) = 1 } }
        n *= 2
    }
    var sum: usize = 0
    unsafe { sum = *p as usize }
    free_raw(p, n, 8)
    return sum
}

fn main() -> i32 {
    var sum  = round() + round()
    var from = minor_faults()
    for var r = 0; r < 40; r += 1 { sum += round() }
    var faults = minor_faults() - from
    // Regrowing into the cached mapping faults nothing; cutting it to the
    // first size and growing again faults every page past that, 480 a round.
    if faults < 2000 { println(f"resident {sum}") } else { println(f"faults {faults}") }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// A block regrown in a loop reuses its freed mapping whole: after two
// rounds, forty more rounds of one block grown from 4 KiB to 2 MiB fault at
// most a few pages each. mimalloc's purge is off so its own timing cannot
// fault pages back in.
// REQUIRES: clang, host-linux
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: env MIMALLOC_PURGE_DELAY=-1 %t.exe | %FileCheck %s
// CHECK: resident 42
