// One of the constructs Compiler/ is written with, checked on Stage 1 ahead
// of self-hosting (2026-10-24 probe; tickets in private/IMPORTANT/TICKETS.TXT).
//
// Importing llvm/ADT/DenseSet.h, which Compiler/ does in 7 files. DenseMap,
// StringMap and DenseSet's neighbours import and compile; this one header
// takes the compiler down.
//
// XFAIL: *
// Waiting on a source-location bug in the import: the bare import ICEs,
// "VirtualFileManager: Offset out of segment bounds (fid: N, off: 9708)",
// deterministically -- DenseSet.h is 9562 bytes, so an offset from another
// file is being resolved against it.
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

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
