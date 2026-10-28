// Calling a method on the class that declares it, when a base declares the
// same name. RESOLUTION.md §2b merges rather than hides, so both are
// candidates; the derived one binds `self` exactly and the base one needs a
// derived-to-base conversion, so the derived one must win (C++ ranks the
// implicit object argument the same way).
//
// XFAIL: *
// Waiting on overload resolution ranking an identity receiver above a
// derived-to-base one: today every such call is SC064E "call to 'k' is
// ambiguous", for an `override` and a plain same-name method alike.
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

class A {
    virtual fn k(self) -> i32 { return 1 }
    fn n(self) -> i32 { return 10 }
}

class D derives A {
    override fn k(self) -> i32 { return 2 }
    fn n(self) -> i32 { return 20 }
}

fn main() -> i32 {
    var r = 0
    var d = D()
    if d.k() == 2 { r += 1 }                    // override, called on the derived value
    var p = &d
    if p->k() == 2 { r += 2 }                   // ... and through a *D
    if d.n() == 20 { r += 4 }                   // non-virtual same name
    var a: *A = &d
    if a->n() == 10 { r += 8 }                  // static type picks A's
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 15
