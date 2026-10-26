// Struct destructuring by field name (variables.mdx, Destructuring;
// structures.mdx): `var {r, g, b} = color` binds each field, and `_` discards
// one.
//
// XFAIL: *
// Ticket "[Sema/Codegen] Struct destructuring (`var {a, b} = s`) is SC116E"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today: SC116E "destructuring a
// struct by field name is not yet supported". When it XPASSes, delete the
// XFAIL -- the run below is already the real assertion.

struct Color {
    pub var r: u8
    pub var g: u8
    pub var b: u8
}

fn main() -> i32 {
    var color = Color { r: 25, g: 12, b: 3 }
    var {r, g, b} = color
    var {x, _, _} = color
    return (r as i32) + (g as i32) + (b as i32) + (x as i32)  // 65
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 65
