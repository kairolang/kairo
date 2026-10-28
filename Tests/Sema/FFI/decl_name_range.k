// A C++ declaration whose printed name is not what is spelled at its
// location. DeclImport ranged every imported name as (location, length of
// getNameAsString()), and an inheriting constructor's name -- `using
// BaseT::BaseT;` names the base's constructor, printed as the whole
// specialization -- ran past the end of the header: "VirtualFileManager:
// Offset out of segment bounds" on the bare import (llvm/ADT/DenseSet.h ends
// exactly like decl_name_range.h). The name's range is now the token clang
// lexes there whenever the bytes are not the printed name.

ffi "c++" import "decl_name_range.h"

fn main() -> i32 {
    var w: Wrapped<i32>
    return w.get()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning|Internal Compiler Error}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 6
