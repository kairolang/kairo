// An initializer on an array-typed field (classes.mdx): a default like any
// other field's.
//
// XFAIL: *
// Ticket "[Sema/Codegen] An initializer on an `eval` or array-typed field is
// SC116E" (private/IMPORTANT/TICKETS.TXT, 2026-10-26), the array half (the
// eval half is Tests/Codegen/eval/field_initializer.k). Today it is SC116E
// "an initializer on an array-typed field is not yet supported": the
// field's default becomes a thunk, and a C++ function cannot return an
// array. When it XPASSes, delete the XFAIL -- the run below is already the
// real assertion.

class C {
    pub var a: [i32; 3] = [1, 2, 3]
}

fn main() -> i32 {
    var c = C()
    return c.a[0] + c.a[2]                      // 1 + 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 4
