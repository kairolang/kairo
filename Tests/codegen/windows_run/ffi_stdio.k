// A C header imported with `ffi ""` links against the Windows C runtime
// and its functions run.

ffi "" import "stdio.h"
ffi "" import "stdlib.h"
ffi "" import "string.h"

fn main() -> i32 {
    var a = abs(-42)
    printf("abs %d\n", a)
    printf("printf %d\n", 17)
    var n = strlen("hello")
    printf("strlen %d\n", n as i32)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: wine, sysroot-x86_64-windows-gnu
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s --target=x86_64-windows-gnu -o %t.exe --cache-dir %t.d
// RUN: %wine %t.exe | %FileCheck %s --match-full-lines
// CHECK: abs 42
// CHECK-NEXT: printf 17
// CHECK-NEXT: strlen 5
