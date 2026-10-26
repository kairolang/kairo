// `===` on nullable pointers compares what they point to, one level down
// (nullables.mdx, Null-aware equality) -- also in a generic function whose
// `T` turns out to be a pointer: `same(a, b)` with `T = *i32` compares the
// two i32s, not the addresses.
//
// XFAIL: *
// Ticket "[Sema] `===` in a generic body decides \"pointee or value\" on the
// written type" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today the
// template is typed once on `T?`, where no pointer is visible, so the
// instance at `T = *i32` compares ADDRESSES: `same(a, b)` is false and the
// program exits 6. When it XPASSes, delete the XFAIL -- the run below is
// already the real assertion.

fn <T> same(a: T?, b: T?) -> bool = a === b

fn main() -> i32 {
    var x: i32 = 1
    var y: i32 = 1
    var a: *i32? = &x
    var b: *i32? = &y
    var r = 0
    if same(a, b) { r += 1 } else { r += 2 }    // pointees equal: 1
    var n: i32? = 5
    var m: i32? = 5
    if same(n, m) { r += 4 }                    // values equal: 4
    return r                                    // 5
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 5
