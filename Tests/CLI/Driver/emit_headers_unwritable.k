// --emit-headers into a directory that cannot be created is an error and a
// nonzero exit; it used to exit 0 having written nothing.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --emit-headers=/proc/no_such_dir/hdr 2>&1 || true; } | %FileCheck %s
// RUN: not %kairo %s --type-check-only --emit-headers=/proc/no_such_dir/hdr > /dev/null 2>&1
// CHECK: error [U001E]: cannot write C++ header
