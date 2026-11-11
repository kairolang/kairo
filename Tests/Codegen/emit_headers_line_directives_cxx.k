// REQUIRES: clang
// kals' clangd bridge headers (--emit-headers-line-directives,
// Compiler/Spec/LanguageServer.md section 15): a C++ compiler reading one
// reports the Kairo file and line for a Kairo declaration, which is what
// makes a jump or a diagnostic from C++ land in the .k file.
pub fn add(a: i32, b: i32) -> i32 {
    return a + b
}

// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/h --emit-headers-line-directives
// RUN: printf '#include "h/emit_headers_line_directives_cxx.hh"\nint f() { return emit_headers_line_directives_cxx::add("x", 2); }\n' > %t.d/use.cc
// RUN: { %clangxx -fsyntax-only %t.d/use.cc 2>&1 || true; } | %FileCheck %s
// CHECK: emit_headers_line_directives_cxx.k:6:{{[0-9]+}}: note: passing argument to parameter
