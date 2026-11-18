// A header the user asks for (--emit-headers) is plain C++ for sharing or a
// system compiler: it never carries #line directives. Only kals' clangd
// bridge asks for them (--emit-headers-line-directives, a hidden flag;
// Compiler/Spec/LanguageServer.md section 15), and kcc's #include "x.k"
// injects tokens with Kairo locations instead.
pub struct Point {
    pub var x: i32
}

pub fn add(a: i32, b: i32) -> i32 {
    return a + b
}

// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/h
// RUN: %FileCheck %s --check-prefix=DECL < %t.d/h/emit_headers_plain_no_line.hh
// RUN: { grep -c '#line' %t.d/h/emit_headers_plain_no_line.hh || true; } | %FileCheck %s --check-prefix=NONE
// DECL: add(signed int a, signed int b)
// NONE: {{^}}0{{$}}
