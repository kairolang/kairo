// `DenseMap<u64, *Entry>` with a Kairo class as the mapped type: the key
// stays `u64`, so `m[k]`, `find(k)`, `count(k)` and `end()` type and the
// found entry's `first` reads back as a `u64`.

ffi "c++" import "llvm/ADT/DenseMap.h"

class Entry { pub var v: i32 = 7 }

fn main() -> i32 {
    var m: llvm::DenseMap<u64, *Entry>
    var e = Entry()
    var k: u64 = 42
    m[k] = &e
    var it = m.find(k)
    if it == m.end() { return 1 }
    var found: u64 = it->first
    var c = m.count(k)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// DIAG-NOT: warning
