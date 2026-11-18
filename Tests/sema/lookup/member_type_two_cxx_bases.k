// A member type two imported bases both declare: two typedefs of one type
// name one type, which C++ accepts (`D::T`); typedefs of two types are
// ambiguous (`E::T`), as clang says.

ffi "c++" import "member_type_two_cxx_bases.h"

class D derives B1, B2 {
    fn D(self) { }
}

class E derives B1, B3 {
    fn E(self) { }
}

fn main() -> i32 {
    var x: D::T = 3
    var y: E::T = 4
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: member_type_two_cxx_bases.k:16:{{.*}}error
// CHECK: member_type_two_cxx_bases.k:17:15: error [R028E]: 'T' is ambiguous in 'E': its bases 'B1' and 'B3' both declare a member 'T'
// CHECK-NOT: error
