// A reserve past the entry limit (2^32: 32-bit entry numbers) traps before
// it allocates.

fn main() -> i32 {
    var m: {u64: u64}
    m.reserve(4294967297)
    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: not --crash %t.exe
