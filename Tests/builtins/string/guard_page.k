// Constructors read only the bytes they are given: every length up to 700
// is built from a range that ends at an unreadable page and from one that
// starts right after one, as ASCII and as text with wide chars. A read
// outside the range is a SIGSEGV. The mmap constants are the Linux values.
ffi "c" import "sys/mman.h"
import std::io

eval REGION: usize = 65536

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

fn main() -> i32 {
    var unsafe *g = guarded()
    if g == &null {
        return 2
    }

    var acc: usize = 0
    unsafe {
        for var wide = 0; wide < 2; wide += 1 {
            for var n: usize = 0; n <= 700; n += 1 {
                // The range ends at the guard page.
                var unsafe *hi = g + REGION - n
                // And one that starts at the first readable byte.
                var unsafe *lo = g
                for var i: usize = 0; i < n; i += 1 {
                    var b: u8 = 97 + ((i % 26) as u8)
                    hi[i] = b
                    lo[i] = b
                }

                if wide == 1 && n >= 2 {
                    // A two-byte char at the very end and at the very start.
                    hi[n - 2] = 0xc3
                    hi[n - 1] = 0xa9
                    lo[0]     = 0xc3
                    lo[1]     = 0xa9
                }

                var a = string(hi as *const u8, n)
                var b = string(lo as *const u8, n)
                var c? = string::from_utf8(Slice<const u8>(hi as unsafe *const u8, n))
                var d? = string::from_utf8(Slice<const u8>(lo as unsafe *const u8, n))
                if a.size() != n || b.size() != n || !c? || !d? {
                    return 1
                }

                acc += a.codepoints() + b.codepoints()
                if c? {
                    acc += c.codepoints()
                }

                // Views of the copies: search and comparison at their ends.
                var needle = "yz"
                var f1 = a.find(needle) ?? 0
                var f2 = b.rfind(needle) ?? 0
                acc += f1 + f2
                var av = a.view()
                if !(a == av) {
                    return 1
                }
            }
        }
    }

    io::println(f"ok {acc}")
    return 0
}

// --- lit wiring ---
// REQUIRES: host-linux
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK: ok {{[0-9]+}}
