// An imported C++ function's defaults are omitted from the call and clang
// applies them: the one place codegen leaves clang a choice, on purpose.

ffi "c++" import "defs.hh"

fn chk(c: bool) -> i32 { if c { return 1 } return 0 }

fn main() -> i32 {
    var n = chk(add_to(2) == 42)
    n += chk(span3(1) == 123)
    n += chk(span3(1, 5) == 153)
    n += chk(span3(a: 4, b: 1) == 413)
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 4
