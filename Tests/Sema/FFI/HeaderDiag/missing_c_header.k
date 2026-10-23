// The failing include itself sits inside `extern "C" { }`: the brace line
// before it maps to nothing, the include line to this import.

ffi "c" import "hd_missing_c.h"

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      missing_c_header.k:4:16: error [CL001E]: 'hd_missing_c.h' file not found
// DIAG-NOT:  <injected>
// DIAG-NOT:  {{error|warning}} [
