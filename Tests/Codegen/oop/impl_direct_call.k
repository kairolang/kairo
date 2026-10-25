// A class conforming with an inline `impl` clause calls its own method
// directly (interfaces.md, Conformance; RESOLUTION.md §2b: conformance
// methods are ordinary members at lookup). `extend X impl I` and
// structural conformance already work; the inline clause is the case here.
//
// XFAIL: *
// Waiting on MemberLookup / overload resolution not offering the
// interface's bodiless requirement beside the method that implements it:
// _walk_record step 3 walks `implements` and appends I's requirement, so
// every direct call is SC064E "ambiguous" -- by value, through a pointer,
// on `self`, and for a static requirement via X::id().
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

interface I {
    fn f(self) -> i32
    static fn id() -> i32
}

class X impl I {
    fn f(self) -> i32 { return 1 }
    static fn id() -> i32 { return 4 }
}

fn <T impl I> via_bound(t: T) -> i32 { return t.f() }

fn main() -> i32 {
    var r = 0
    var x = X()
    if x.f() == 1 { r += 1 }
    var p = &x
    if p->f() == 1 { r += 2 }
    if X::id() == 4 { r += 4 }
    if via_bound(X()) == 1 { r += 8 }           // works today; keeps the bound path honest
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 15
