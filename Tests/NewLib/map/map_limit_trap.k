// A reserve past the entry limit (2^32 - 2^29 at 8-byte slots) traps before
// it allocates.

fn main() -> i32 {
    var m: {u64: u64}
    m.reserve(3758096385)
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: not --crash %t.exe
