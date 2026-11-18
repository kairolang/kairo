// Doc comments reach the generated header only in layout mode, which exists
// for the clangd overlay: there each `///` sits on the line of its
// declaration. Plain --emit-headers (the header kcc includes and C++ code
// consumes) carries no doc comments, so the two modes stay distinguishable
// and a plain header does not change when a doc comment is edited.

/// doc for the function
pub fn f() -> i32 { return 2 }

pub class C {
    /// doc for the method
    pub fn m(self) -> i32 { return 1 }
}

// --- lit wiring ---
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/plain
// RUN: not grep -F '///' %t.d/plain/emit_headers_docs_layout_only.hh
// RUN: not grep -F 'doc for' %t.d/plain/emit_headers_docs_layout_only.hh
// RUN: grep -F 'signed int f()' %t.d/plain/emit_headers_docs_layout_only.hh
//
// RUN: %kairo %s --type-check-only --emit-headers %t.d/layout --emit-headers-layout
// RUN: %FileCheck %s --check-prefix=LAYOUT < %t.d/layout/emit_headers_docs_layout_only.hh
// LAYOUT: /// doc for the function
// LAYOUT: /// doc for the method
