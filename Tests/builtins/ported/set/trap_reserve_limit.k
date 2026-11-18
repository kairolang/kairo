// A reserve past the entry limit of a HashSet (2^32 elements: entry numbers are 32 bits) traps
// before it allocates; the same limit the map documents.

fn main() -> i32 {
    var s: {u64}
    s.reserve(4294967297)
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: not --crash %t.exe
