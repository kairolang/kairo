// kals' clangd bridge: under --emit-headers-layout an enum's variants
// each sit on their own line (the enum's closing brace is anchored at the
// enum and does not pull every variant onto the enum's line), a field after
// an access specifier keeps its own line, and a function above the enum it
// names moves up past the enum's niche specialization. The checks read
// single physical lines of the header; clang compiles it.

/// Picks one.
pub fn pick(c: Color) -> i32 { return 1 }

/// A colour.
pub enum Color {
    /// The red one.
    Red,
    Green = 5,
}

pub class Box {
    var hidden: i32
    pub fn Box(self) = default
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/h --emit-headers-layout
// RUN: sed -n 8p %t.d/h/emit_headers_layout_lines.hh | %FileCheck %s --check-prefix=L8
// RUN: sed -n 9p %t.d/h/emit_headers_layout_lines.hh | %FileCheck %s --check-prefix=L9
// RUN: sed -n 12p %t.d/h/emit_headers_layout_lines.hh | %FileCheck %s --check-prefix=L12
// RUN: sed -n 13p %t.d/h/emit_headers_layout_lines.hh | %FileCheck %s --check-prefix=L13
// RUN: sed -n 14p %t.d/h/emit_headers_layout_lines.hh | %FileCheck %s --check-prefix=L14
// RUN: sed -n 15p %t.d/h/emit_headers_layout_lines.hh | %FileCheck %s --check-prefix=L15
// RUN: sed -n 18p %t.d/h/emit_headers_layout_lines.hh | %FileCheck %s --check-prefix=L18
// RUN: sed -n 19p %t.d/h/emit_headers_layout_lines.hh | %FileCheck %s --check-prefix=L19
// RUN: printf '#include "h/emit_headers_layout_lines.hh"\nint f() { emit_headers_layout_lines::Box b; return emit_headers_layout_lines::pick(emit_headers_layout_lines::Color::Green); }\n' > %t.d/use.cc
// RUN: %clangxx -fsyntax-only %t.d/use.cc
// L8: /// Picks one.
// L9: pick(
// L12: enum class Color
// L13: /// The red one.
// L14: Red = 0,
// L15: Green = 5,
// L18: class Box
// L19: hidden
