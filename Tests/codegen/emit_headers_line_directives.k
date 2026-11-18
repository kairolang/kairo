// kals' clangd bridge (Compiler/Spec/LanguageServer.md section 15): with
// --emit-headers-line-directives every emitted line sits under a #line
// naming the Kairo declaration it comes from, and invented text (pragma,
// helpers, namespace braces) under one naming the header itself, so a C++
// compiler reading the header reports Kairo locations.
pub struct Point {
    pub var x: i32
}

pub fn add(a: i32, b: i32) -> i32 {
    return a + b
}

// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/h --emit-headers-line-directives
// RUN: %FileCheck %s --check-prefix=LINE < %t.d/h/emit_headers_line_directives.hh
// LINE: #line 2 "{{.*}}emit_headers_line_directives.hh"
// LINE-NEXT: #pragma once
// LINE: #line 6 "{{.*}}emit_headers_line_directives.k"
// LINE: struct Point;
// LINE: #line 10 "{{.*}}emit_headers_line_directives.k"
// LINE-NEXT: namespace emit_headers_line_directives {
// LINE-NEXT: #line 10 "{{.*}}emit_headers_line_directives.k"
// LINE-NEXT: {{.*}}add(signed int a, signed int b)
