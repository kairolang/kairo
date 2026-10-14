// --no-cxx rejects only the ffi "c++" import; the ffi "c" import beside it
// stays legal (--no-ffi is the flag that rejects both). Without the flag the
// file is accepted.

ffi "c" import "stdlib.h"
ffi "c++" import "map"

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only %s
// RUN: { %kairo --type-check-only --no-cxx %s 2>&1 || true; } | %FileCheck %s
// CHECK: no_cxx.k:6:{{[0-9]+}}: error [SC001E]: an ffi "c++" import is not allowed when C++ interop is disabled
// CHECK-NOT: error [SC001E]
