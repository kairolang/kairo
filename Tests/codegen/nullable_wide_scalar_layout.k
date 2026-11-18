// A nullable 64-bit scalar is laid out as the target's C++ type lays it out:
// the 8-byte payload sits at the target's own alignment, so the nullable is
// 16 bytes where a 64-bit scalar is 8-aligned (x86_64) and 12 bytes where it
// is 4-aligned (i686), and a nullable 32-bit scalar is 8 bytes on both.

fn main() -> i32 {
    var want: usize = if sizeof usize == 8 => 16 else => 12
    var bad = 0
    if sizeof (u64?) != want { bad = bad + 1 }
    if sizeof (i64?) != want { bad = bad + 2 }
    if sizeof (f64?) != want { bad = bad + 4 }
    if sizeof (i32?) != 8 { bad = bad + 8 }
    return bad
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.e
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.e
// RUN: %t.o2.exe
