// An integer literal with a Kairo type suffix (`0xFFu8`, `7i64`) reaches C++
// as its value: the suffix is Kairo's, and clang rejected the borrowed bytes
// ("invalid suffix 'u8' on integer constant"). A value with the top bit set
// spells ULL.

fn main() -> i32 {
    var a: u8 = 0xFFu8
    var b: i64 = 7i64
    var c: u64 = 0xFFFFFFFFFFFFFFFFu64
    var ok: i32 = 0
    if a == 255 { ok += 1 }
    if b == 7 { ok += 1 }
    if c == 18446744073709551615u64 { ok += 1 }
    return ok
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -o %t.d/run --cache-dir %t.d/o 2>&1 | %FileCheck %s --allow-empty
// CHECK-NOT: {{error|warning}}
// RUN: %t.d/run; test $? -eq 3
