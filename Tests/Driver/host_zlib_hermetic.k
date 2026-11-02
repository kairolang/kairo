// zlib.h is a host header the floor lacks: the default build finds it after
// the floor's headers, and a --target build, which is hermetic, does not.

ffi "c" import "zlib.h"

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-glibc, pkg-zlib
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=FLOOR
// FLOOR-NOT: file not found
// RUN: { %kairo %s --target=x86_64-linux-gnu --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=HERM
// HERM: error [CL001E]: 'zlib.h' file not found
