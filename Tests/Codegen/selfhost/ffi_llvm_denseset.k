// One of the constructs Compiler/ is written with, checked on Stage 1 ahead
// of self-hosting (2026-10-24 probe; tickets in private/IMPORTANT/TICKETS.TXT).
//
// Importing llvm/ADT/DenseSet.h, which Compiler/ does in 7 files.
//
// This used to ICE on the bare import, "VirtualFileManager: Offset out of
// segment bounds (fid: N, off: 9708)": DenseSet.h ends with `using
// BaseT::BaseT;`, an inheriting constructor whose printed name (the whole
// base specialization) ran past the file's last byte when DeclImport ranged
// the name by its printed length. Generic shape: Sema/FFI/decl_name_range.k.

ffi "c++" import "llvm/ADT/DenseSet.h"

fn main() -> i32 {
    var s: llvm::DenseSet<u64>
    var k: u64 = 7
    s.insert(k)
    if s.contains(k) { return 1 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// The LLVM headers are the in-tree ones Compiler/ itself builds against.
// RUN: { %kairo %s --type-check-only --ffi-include %S/../../../Lib/llvm-runtimes/llvm/include --ffi-include %S/../../../build/llvm/include 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
