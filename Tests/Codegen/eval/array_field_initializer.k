// An initializer on an array-typed field (classes.mdx): a default like any
// other field's. No C++ function returns an array, so FieldInitLowering
// makes a thunk of each ELEMENT of the list literal and the C++ default
// member initializer lists their calls (FieldFold::Elems).

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
