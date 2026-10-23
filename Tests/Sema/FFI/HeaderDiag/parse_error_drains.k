// A .k parse error stops the run before Sema, which used to be the only
// place a header set's buffered clang diagnostics drained. The undrained
// BufferedDiagSink then ICEd ("dropped without drain") in ~CompilerInstance.
// Every early-exit mode must report both errors and exit cleanly.

ffi "c++" import "unknown_type.h"

fn main() -> i32 {
    open("f", "r") as f { }
}

// RUN: { %kairo %s 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-DAG:  parse_error_drains.k:9:20: error [S058E]: expected 'var' or 'const' to begin a binding
// DIAG-DAG:  unknown_type.h:3:12: error [CL001E]: unknown type name 'bar'
// DIAG-NOT:  Internal Compiler Error

// --preprocess never parses: only the header's error, still no ICE.
// RUN: { %kairo %s --preprocess 2>&1 || true; } | %FileCheck %s --check-prefix=PP
// PP:        unknown_type.h:3:12: error [CL001E]: unknown type name 'bar'
// PP-NOT:    Internal Compiler Error
