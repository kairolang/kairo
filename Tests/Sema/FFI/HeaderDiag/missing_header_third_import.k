// The injected buffer has one `#include` line per header, in import order;
// the third import's failure must map to the third import, not the first.

ffi "c++" import "ok.h"
ffi "c++" import "c_ok.h"
ffi "c++" import "hd_missing_third.h"

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      missing_header_third_import.k:6:18: error [CL001E]: 'hd_missing_third.h' file not found
// DIAG-NOT:  <injected>
// DIAG-NOT:  {{error|warning}} [
