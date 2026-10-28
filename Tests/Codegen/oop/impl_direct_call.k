// A class conforming with an inline `impl` clause calls its own method
// directly (interfaces.md, Conformance; RESOLUTION.md §2b: conformance
// methods are ordinary members at lookup). `extend X impl I` and
// structural conformance always worked; the inline clause is the case here.
// MemberLookup::_walk_record used to walk `implements` and offer I's
// bodiless requirement beside X's method, so every direct call was SC064E
// "ambiguous" -- by value, through a pointer, on `self`, and for a static
// requirement via X::id(). Interfaces have no default bodies, so the walk
// no longer visits them.

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
    var *p = &x
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
