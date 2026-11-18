// An error inside a macro expansion is blamed on the EXPANSION site in the
// header (the adapter decomposes the expansion loc), not the #define.

ffi "c++" import "macro_error.h"

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      macro_error.h:2:1: error [CL001E]: unknown type name 'undeclared_t'
// DIAG-NOT:  {{error|warning}} [
