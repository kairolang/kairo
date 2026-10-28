// Raw allocation with `std::alloc<T>(bytes)` and `std::free(p)`, each in an
// unsafe context (pointers.mdx; unsafe.mdx: `var buf: unsafe *u8 = unsafe
// std::alloc<u8>(1024)`).
//
// XFAIL: *
// Ticket "[Lib] `std::alloc` / `std::free` do not exist"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today: R025E "no member named
// 'alloc' in module 'std'" (and 'free'). When they land they must require an
// unsafe context: the docs' Buffer example in classes-lifecycle.mdx calls
// them without one, filed as a docs bug. When it XPASSes, delete the XFAIL --
// the run below is already the real assertion.

import std

fn main() -> i32 {
    var raw: unsafe *i32 = unsafe std::alloc<i32>(sizeof i32 * 2)
    unsafe { *raw = 40 }
    unsafe { *(raw + 1) = 2 }
    var r: i32
    unsafe { r = *raw + *(raw + 1) }
    unsafe std::free(raw)
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
