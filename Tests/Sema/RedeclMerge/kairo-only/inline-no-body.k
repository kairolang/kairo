// NO ORACLE: C++ accepts an inline declaration that is never defined until
// something odr-uses it. In Kairo `inline` puts the body in the interface,
// so a declaration without one would be declared inline in C++ with a
// definition nowhere: R001E at the declaration, whether or not it is used.
//
// EXPECT-ERROR: 14: inline-without-body
// EXPECT-ERROR: 17: inline-without-body

class Bar {
    // Defined out of line below: the chain has the body, so no error.
    inline fn a(self) -> i32
    inline fn d(self) -> i32 { return 4 }
    // Never defined.
    inline fn e(self) -> i32
}
inline fn Bar::a(self) -> i32 { return 1 }
inline fn free_decl(x: i32) -> i32

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// Kept at the BOTTOM on purpose: the EXPECT-ERROR annotations above name
// absolute LINE NUMBERS in the code.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: inline-no-body.k:14:5: error [R001E]: 'e' is declared inline but has no body
// CHECK: inline-no-body.k:17:1: error [R001E]: 'free_decl' is declared inline but has no body
// CHECK-NOT: error
