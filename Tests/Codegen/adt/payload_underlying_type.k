// A payload enum with a declared underlying type (enums-adt.mdx; enums-
// plain.mdx, `derives u8`): the tag is that type, so `E` below is a u8 tag
// and a u8 payload, two bytes.
//
// XFAIL: *
// Ticket "[Sema/Codegen] A payload enum's declared underlying type is
// ignored" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today `derives u8` is
// accepted and ignored: the tag is always u32, so `sizeof E` is 8 and the
// program exits 8 (GitHub #98). When it XPASSes, delete the XFAIL -- the run
// below is already the real assertion.

enum E derives u8 {
    A { x: u8 },
    B,
}

fn main() -> i32 {
    return sizeof E as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 2
