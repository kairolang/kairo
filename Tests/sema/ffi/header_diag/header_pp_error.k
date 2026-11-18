// `#error` and `#warning` in a header are located diagnostics in the header.

ffi "c++" import "pp_error.h"
ffi "c++" import "warning.h"

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-DAG:  pp_error.h:2:2: error [{{[A-Z]+[0-9]+}}E]: "hd custom error"
// DIAG-DAG:  warning.h:1:2: warning [{{[A-Z]+[0-9]+}}W]: "hd custom warning"
// DIAG-NOT:  <injected>
