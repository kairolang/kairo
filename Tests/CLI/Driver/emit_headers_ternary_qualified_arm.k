// The header printer keeps the space between `:` and a global-qualified
// name: a generic function's body is printed into the header, and
// `c ? a : ::ns::g` must not become `c ? a :::ns::g` (a lexical error in
// C++). The printed header compiles with clang.

pub var g_fallback: i32 = 9

pub fn <T> pick(c: bool, a: i32) -> i32 {
    return if c => a else => g_fallback
}

fn main() -> i32 { return pick<i32>(false, 1) - 9 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/h
// RUN: %FileCheck %s --input-file=%t.d/h/emit_headers_ternary_qualified_arm.hh
// CHECK: (c ? a : ::emit_headers_ternary_qualified_arm::g_fallback)
// CHECK-NOT: :::
// RUN: printf '#include "h/emit_headers_ternary_qualified_arm.hh"\nint f() { return emit_headers_ternary_qualified_arm::pick<int>(true, 1); }\n' > %t.d/use.cc
// RUN: %clangxx -fsyntax-only %t.d/use.cc
