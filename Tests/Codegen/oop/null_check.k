// The postfix null check, `if p? { ... }` (nullables.md, Null checking),
// and using the checked value inside the branch as the non-null type:
// `*p` and `p->m()` on a pointer, the value itself on a `T?`.
//
// XFAIL: *
// Postfix `?` is typed and lowered since NULLABLE.md G5 (`p?` is bool,
// `!p.is_null()` in C++); what remains is the NARROWING. `p->m()` on a
// narrowed `(*A)?` must look through the Nullable -- today it is R027E
// "'->' requires a pointer on its left" (G16), which stops the build before
// typing; past it, `return p` / `*p` inside `if p?` still read `i32?` /
// `(*i32)?` and are SC028E / SC070E until the nullness environment narrows
// them (G11) and NarrowedAccessLowering reads them (G16).
// When those land this test XPASSes; delete the XFAIL -- the run below is
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
