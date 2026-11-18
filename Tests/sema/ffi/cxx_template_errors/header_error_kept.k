ffi "c++" import "inputs/uses.h"

fn main() -> i32 {
    return header_only()
}

// --- lit wiring ---
// An error whose instantiation chain never reaches Kairo code stays where
// clang reports it, under clang's own code.
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --implicit-check-not=CL002E --implicit-check-not=SC302E
//
// CHECK: uses.h:9:{{[0-9]+}}: error [CL001E]: static assertion failed due to requirement 'sizeof(int) == 0': Never<T> is never instantiable
// CHECK-NEXT: uses.h:12:{{[0-9]+}}: note [I900N]: in instantiation of template class 'Never<int>' requested here
