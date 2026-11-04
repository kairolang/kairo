import scan_a::*
import scan_b::*

fn main() -> i32 {
    var buf: [u8; 16] = [0, 0, 0, 10, 0, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0]
    var a = count_a(&buf[0])
    var b = count_b(&buf[0])
    if (a != 0x208) || (b != 0x208) { return 1 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, host-x86_64
// RUN: rm -rf %t.d
// RUN: { %kairo %s -c --print-ir --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// CHECK-LABEL: scan_b.k
// CHECK: const __attribute((__vector_size__(2 * sizeof(long long)))) long long nl =
// CHECK-LABEL: scan_a.k
// CHECK: const __attribute((__vector_size__(2 * sizeof(long long)))) long long nl =
