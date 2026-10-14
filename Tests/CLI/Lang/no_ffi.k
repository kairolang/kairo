// --no-ffi turns every ffi import into an error, C and C++ alike. Without the
// flag the file is accepted.

ffi "c" import "stdlib.h"
ffi "c++" import "map"

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only %s
// RUN: { %kairo --type-check-only --no-ffi %s 2>&1 || true; } | %FileCheck %s
// CHECK: no_ffi.k:4:{{[0-9]+}}: error [SC001E]: an ffi import is not allowed when ffi is disabled
// CHECK: no_ffi.k:5:{{[0-9]+}}: error [SC001E]: an ffi import is not allowed when ffi is disabled
