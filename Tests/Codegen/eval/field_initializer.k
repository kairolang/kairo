// A field initializer on an `eval` field and on an array-typed field
// (classes.mdx; eval.mdx): both are defaults like any other field's.
//
// XFAIL: *
// Ticket "[Sema/Codegen] An initializer on an `eval` or array-typed field is
// SC116E" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today both are SC116E:
// "an initializer on an eval field is not yet supported" and "an initializer
// on an array-typed field is not yet supported" (status.mdx, Not Compiled
// Yet). When it XPASSes, delete the XFAIL -- the run below is already the
// real assertion.

class C {
    eval K: i32 = 3
    pub var a: [i32; 3] = [1, 2, 3]
}

fn main() -> i32 {
    var c = C()
    return C::K + c.a[0] + c.a[2]               // 3 + 1 + 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
