// A missing include two headers deep is blamed on the `#include` line in
// the header that wrote it, not on this import and not on <injected>.

ffi "c++" import "two_deep.h"

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      nested_missing.h:3:10: error [CL001E]: 'hd_does_not_exist.h' file not found
// DIAG-NOT:  <injected>
// DIAG-NOT:  {{error|warning}} [
