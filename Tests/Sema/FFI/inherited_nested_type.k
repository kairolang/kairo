// A type nested in an IMPORTED class's base is named through the derived
// class, as C++ does (`clang::TargetInfo::IntType` is declared in its base
// TransferrableTargetInfo). A miss in the class's own table walks the
// bases, nearest first.

ffi "c++" import "inherited_nested_type.h"

fn f(a: NDer::IntType, b: NMid::Inner, c: NDer::Td) -> NDer::Td { return c }
fn g() -> i32 {
    var k: NDer::IntType = NDer::NoInt
    var i: NDer::Inner
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: error
