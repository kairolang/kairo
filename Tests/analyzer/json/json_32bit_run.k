// Every case of analyzer/JsonTest.k, built for i686, where usize is 32 bits
// wide, and run on an x86_64 Linux host, which runs i686 static binaries.
// The exponent cases cover the accumulator past 2^32.

import JsonTest::Test

fn main() -> i32 {
    return Test()
}

// --- lit wiring ---
// REQUIRES: sysroot-i686-linux-musl
// REQUIRES: host-x86_64
// REQUIRES: host-linux
// RUN: rm -f %t.exe
// RUN: %kairo %s -I %S/../../../Analyzer --target i686-linux-musl -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe | %FileCheck %s
// CHECK: json: {{[0-9]+}} cases, 0 failed
