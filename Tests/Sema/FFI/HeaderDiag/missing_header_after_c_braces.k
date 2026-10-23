// An `ffi "c"` header is wrapped in `extern "C" {` / `}` lines in the
// injected buffer, so buffer line != import index. Two C imports put six
// lines ahead of the failing include; the map must still find line 7.

ffi "c" import "c_ok.h"
ffi "c" import "ok.h"
ffi "c++" import "hd_missing_cxx.h"

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      missing_header_after_c_braces.k:7:18: error [CL001E]: 'hd_missing_cxx.h' file not found
// DIAG-NOT:  <injected>
// DIAG-NOT:  {{error|warning}} [
