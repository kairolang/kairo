// A generic closure (closures.mdx, Generic Closures): `fn <T>(x: T) -> T`
// is called at more than one type.
//
// XFAIL: *
// Ticket "[Sema] Generic closures are gated (SC116E)"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today: SC116E "a generic
// closure is not yet supported" (FeatureGateCheck). Needs TypeResolve for
// closure generic parameters, a closure type that is not one `fn(...)`
// canonical, call typing that deduces it, and a C++ generic lambda. When it
// lands, also drop the `bad_generic` case from Sema/Check/closure_captures.k.
// When it XPASSes, delete the XFAIL -- the run below is already the real
// assertion.

fn main() -> i32 {
    var identity = fn <T>(x: T) -> T {
        return x
    }
    var a = identity(40)
    var b = identity(true)
    if b { return a + 2 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
