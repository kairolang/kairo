// The language server's JSON reader (analyzer/Json.k) compiles for 32-bit
// targets, where usize is 32 bits wide: no constant in it needs a 64-bit
// usize. json_32bit_run.k runs the cases on one.

import JsonTest::Test

fn main() -> i32 {
    return Test()
}

// --- lit wiring ---
// REQUIRES: sysroot-armv7-linux-musl
// REQUIRES: sysroot-i686-linux-musl
// RUN: %kairo %s -I %S/../../../Analyzer --target armv7-linux-musl --type-check-only
// RUN: %kairo %s -I %S/../../../Analyzer --target i686-linux-musl --type-check-only
