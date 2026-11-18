// A header that ends mid-declaration: clang blames the header for the bad
// token and the injected buffer for running out of input. The latter is the
// import line, so both errors land in a file the user owns.

ffi "c++" import "truncated.h"

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-DAG:  header_truncated.k:5:18: error [CL001E]: expected unqualified-id
// DIAG-DAG:  truncated.h:1:1: error [CL001E]: unknown type name 's'
// DIAG-NOT:  <injected>
