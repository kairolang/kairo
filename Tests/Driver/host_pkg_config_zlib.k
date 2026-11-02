// zlib.h from the host in the default build, linked with --pkg-config zlib.
// XFAIL: *
// Waiting on the R016E ticket for C typedefs that share a builtin prelude
// name: zconf.h's `typedef unsigned char Byte` makes `pub import
// base::byte_t::*` in Lib/builtin/module.k ambiguous, before any use of
// either. The header is found and the link is right; the type check fails.
// When that lands, drop the expected failure; the RUN lines are the real assertions.

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
