// `unsafe { e }` in expression position is an unsafe block whose value is
// `e` (unsafe.mdx): here the body of an expression-bodied function.
//
// XFAIL: *
// Ticket "[Parser] `unsafe { e }` in expression position parses its braces
// as a set literal" (private/IMPORTANT/TICKETS.TXT, 2026-10-25; GitHub
// #96). Today the braces after `unsafe` are read as the set literal `{*p}`:
// SC028E "cannot convert '{i32}' to 'i32'". Passes once the parser reads
// `unsafe {` in value position as a block expression. When it XPASSes,
// delete the XFAIL -- the run below is already the real assertion.

fn read(p: unsafe *i32) -> i32 = unsafe { *p }

fn main() -> i32 {
    var x: i32 = 4
    var p: unsafe *i32
    unsafe { p = &x as unsafe *i32 }
    return read(p)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 4
