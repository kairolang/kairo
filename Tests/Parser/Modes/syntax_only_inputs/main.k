// --syntax-only checks the syntax of its inputs only. It used to parse
// the whole import closure (reporting every imported file's syntax errors,
// once per input that reached it) and hand every ffi "c++" header to clang,
// so a self-host run spent 30-60 s per file re-parsing Sema and the driver.
// The closure is still preprocessed (an imported macro expands in this
// file's tokens) and indexed (the parser disambiguates `pick<i32>(1)` against
// lib.k's generic), but it is not parsed, and no header is.
//
// --type-check-only still reports both: lib.k's error and the header's.

import lib::*
ffi "c++" import "no_such_header_p355.h"

fn main() -> i32 {
    var n = pick<i32>(1)
    return n
}

// --- lit wiring ---
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=SYN --allow-empty
// SYN-NOT: lib.k
// SYN-NOT: no_such_header_p355.h
// SYN-NOT: error [

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC
// TC-DAG: lib.k:{{[0-9]+}}:{{[0-9]+}}: error [S
// TC-DAG: no_such_header_p355.h
