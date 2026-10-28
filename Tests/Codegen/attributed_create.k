// Heap allocation with `@create T(args)` in expression position
// (attributes.mdx; modules.mdx: `var *p = @create i32(42)`).
//
// XFAIL: *
// Ticket "[Sema/Codegen] Expression attributes (`@create T(args)`) are
// SC116E" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today: SC116E "the
// expression attribute '@create' is not yet supported" (8b68415b parses it
// and gates it; Sema/Check/attributed_expr_gate.k pins the gate, and changes
// when this lands). When it XPASSes, delete the XFAIL -- the run below is
// already the real assertion.

fn main() -> i32 {
    var *p = @create i32(42)
    return *p
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
