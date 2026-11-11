// zlib.h from the host in the default build, linked with --pkg-config zlib.
// zconf.h's `typedef unsigned char Byte` shares a builtin prelude name; that is
// an error only where the bare name is used, never at the import.

ffi "c" import "zlib.h"

fn main() -> i32 {
    var unsafe *v = zlibVersion()
    if v == &null { return 1 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-glibc, pkg-zlib
// RUN: rm -rf %t && mkdir -p %t
// RUN: %kairo %s --type-check-only
// RUN: %kairo %s --pkg-config zlib -o %t/a.out
// RUN: %t/a.out
