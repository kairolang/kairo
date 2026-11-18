// rule: nothing reaches std without importing it. There is no std prelude --
// builtin is the only one -- so bare `std` in a file that wrote no `import
// std...` is an ordinary undeclared name, and the root is not even loaded.

fn no_import() -> void {
    std::io::println("x")
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: error [R020E]: use of undeclared identifier 'std'
//
// The graph holds builtin and this file, nothing under Lib/std.
// RUN: { %kairo %s --type-check-only --print-imports 2>/dev/null || true; } | %FileCheck %s --check-prefix=IMP
// IMP: <prelude> import builtin::*
// IMP-NOT: kairo::std
