// Every error in a header is reported, each at its own line, in source
// order (BufferedDiagSink sorts on drain); a clean line between them is not.

ffi "c++" import "multi_error.h"

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      multi_error.h:1:12: error [CL001E]: unknown type name 'nope1'
// DIAG-NEXT: multi_error.h:3:14: error [CL001E]: unknown type name 'nope3'
// DIAG-NOT:  {{error|warning}} [
