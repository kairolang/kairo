// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
//
// size_t, uintptr_t -> usize and ptrdiff_t, intptr_t -> isize. Canonical
// `size_t` is `unsigned long`, i.e. u64: the right width but the wrong
// type, since usize does not convert to u64 implicitly, so every size_t
// parameter used to reject a usize argument. The typedef is read off the
// sugar before canonicalization drops it. A plain `unsigned long` is still
// C's unsigned long, not usize: u64 on LP64 and u32 on LLP64, so a u32 goes
// in and a u64 comes out on both, and neither would bind to a usize.

ffi "c++" import "size_t.h"

fn use_sizes(n: usize, d: isize, w: u32) {
    var a: usize = take_size(n)
    var b: isize = take_diff(d)
    var c: usize = take_uptr(n)
    var e: isize = take_iptr(d)
    var f: usize = take_const(n)
    var g: u64   = take_ulong(w)
}

// DIAG-NOT: error
