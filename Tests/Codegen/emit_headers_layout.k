// kals' clangd bridge (Compiler/Spec/LanguageServer.md section 15):
// --emit-headers-layout puts each declaration of the header on the PHYSICAL
// line it has here, because clangd reports physical lines whatever #line
// says. What the emitter invents is in a .prelude beside the header,
// included from line 1. The checks read single physical lines of the header.
pub struct Point {
    pub var x: i32

    pub var y: i32
}

pub fn add(a: i32,
           b: i32) -> i32 {
    return a + b
}


pub fn twice(p: Point) -> i32 { return p.x * 2 }

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/h --emit-headers-layout
// RUN: sed -n 1p %t.d/h/emit_headers_layout.hh | %FileCheck %s --check-prefix=L1
// RUN: sed -n 6p %t.d/h/emit_headers_layout.hh | %FileCheck %s --check-prefix=L6
// RUN: sed -n 7p %t.d/h/emit_headers_layout.hh | %FileCheck %s --check-prefix=L7
// RUN: sed -n 9p %t.d/h/emit_headers_layout.hh | %FileCheck %s --check-prefix=L9
// RUN: sed -n 12p %t.d/h/emit_headers_layout.hh | %FileCheck %s --check-prefix=L12
// RUN: sed -n 18p %t.d/h/emit_headers_layout.hh | %FileCheck %s --check-prefix=L18
// RUN: %FileCheck %s --check-prefix=PRE < %t.d/h/emit_headers_layout.hh.prelude
// RUN: printf '#include "h/emit_headers_layout.hh"\n#include "h/emit_headers_layout.hh"\nint f() { return emit_headers_layout::add("x", 2); }\n' > %t.d/use.cc
// RUN: { %clangxx -fsyntax-only %t.d/use.cc 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// L1: #include "{{.*}}emit_headers_layout.hh.prelude"
// L6: struct Point
// L7: x
// L9: y
// L12: add(
// L18: twice(
// PRE: #pragma once
// PRE: __KAIRO_LOWER_HELPERS
// CXX: emit_headers_layout.k:12:{{[0-9]+}}: note: passing argument to parameter 'a'
