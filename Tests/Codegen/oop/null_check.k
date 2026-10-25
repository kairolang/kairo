// The postfix null check, `if p? { ... }` (nullables.md, Null checking),
// and using the checked value inside the branch as the non-null type:
// `*p` and `p->m()` on a pointer, the value itself on a `T?`.
//
// XFAIL: *
// Waiting on Sema typing postfix `?`: every use is SC066E "unary operator
// '?' is not defined on 'i32?'" (and on `(*i32)?`). After it, `p->m()` on
// a narrowed `(*A)?` must look through the Nullable -- today it is R027E
// "'->' requires a pointer on its left". Then NullableTypeLowering
// (nullable_pointer.k) for the run.
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

class A { virtual fn k(self) -> i32 { return 3 } }

fn val(p: i32?) -> i32 {
    if p? { return p }
    return 0
}

fn deref(p: (*i32)?) -> i32 {
    if p? { return *p }
    return 0
}

fn call(p: (*A)?) -> i32 {
    if p? { return p->k() }
    return 0
}

fn main() -> i32 {
    var r = 0
    if val(4) == 4 { r += 1 }
    var n = 8
    if deref(&n) == 8 { r += 2 }
    var a = A()
    if call(&a) == 3 { r += 4 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
