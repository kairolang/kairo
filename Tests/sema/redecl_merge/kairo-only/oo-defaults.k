// rule: an out-of-line definition may not carry a default, whether it
// re-specifies one (f) or adds one the declaration lacks (g). C++
// accepts g's; Kairo does not: defaults belong to the in-class
// declaration.
//
// NO ORACLE: ported from clang/test/CXX/dcl.decl/dcl.meaning/
// dcl.fct.default/p4.cpp, where g's added default is legal C++. The
// difference is a deliberate Kairo rule (R056E), so the case lives here.
//
// EXPECT-ERROR: 18: default-on-out-of-line-definition
// EXPECT-ERROR: 20: default-on-out-of-line-definition

class C {
    fn f(i: i32 = 3)
    fn g(i: i32, j: i32 = 99)
}

fn C::f(i: i32 = 3) { }

fn C::g(i: i32 = 88, j: i32) { }

// --- lit wiring -----------------------------------------------------------
// Kept at the BOTTOM on purpose: the EXPECT-ERROR annotations above name
// absolute LINE NUMBERS in the code, so anything inserted above the code
// silently invalidates them.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: oo-defaults.k:18:{{[0-9]+}}: error [R056E]: a default argument for 'i' cannot be written on an out-of-line definition
// DIAG: oo-defaults.k:20:{{[0-9]+}}: error [R056E]: a default argument for 'i' cannot be written on an out-of-line definition
// DIAG-NOT: R040E
