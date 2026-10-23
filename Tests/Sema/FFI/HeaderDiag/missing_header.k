// A quoted ffi header that does not exist. clang reports it against the
// header set's synthesized `#include` line; the diagnostic must land on the
// .k import's header string, never on `<injected>:1:10`.

ffi "c++" import "hd_missing.h"

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      missing_header.k:5:18: error [CL001E]: 'hd_missing.h' file not found
// DIAG-NOT:  <injected>
// DIAG-NOT:  {{error|warning}} [
