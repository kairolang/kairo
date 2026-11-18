// The same for a header imported as C: the extern "C" wrapper lives in the
// injected buffer, not the header, so the header's offsets are untouched.

ffi "c" import "c_bad.h"

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      c_bad.h:1:14: error [CL001E]: unknown type name 'nope_c'
// DIAG-NOT:  {{error|warning}} [
