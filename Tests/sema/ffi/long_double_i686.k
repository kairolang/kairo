// `long double` is a real float type on every target, including the 96-bit
// x87 format of i686: a header function taking and returning it imports as
// f80, so an f80 argument matches and the result is an f80. The import does
// not leave it opaque (which made every Kairo program fail on the library's
// put_f80).

import std::io

ffi "c++" import "long_double_i686.h"

fn main() -> i32 {
    var x: f80 = 2.5
    var y: f80 = twice_ld(x)
    io::println(f"{y}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-i686-linux-musl
// RUN: { %kairo %s --target=i686-linux-musl --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=OK --allow-empty --implicit-check-not='error ['
// OK-NOT: error
