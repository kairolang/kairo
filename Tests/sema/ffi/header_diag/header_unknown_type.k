// An error INSIDE a header is reported at the header's own line:col, as a
// located diagnostic (the header is loaded into the source manager at
// build time), not as `path:line:col:` text glued onto a loc-less message.

ffi "c++" import "unknown_type.h"

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      unknown_type.h:3:12: error [CL001E]: unknown type name 'bar'
// DIAG-NOT:  {{error|warning}} [

// The pretty renderer can only show the line if the location is real.
// RUN: { %kairo %s --type-check-only --error-format=pretty 2>&1 || true; } | %FileCheck %s --check-prefix=PRETTY
// PRETTY:      error @ {{.*}}unknown_type.h:3
// PRETTY:      3 | int hd_bad(bar food);
// PRETTY-NEXT:   |            ^
// PRETTY-NEXT:   |            [CL001E] unknown type name 'bar'
