// A failed assert prints its message on stderr and ends the process with a
// non-zero exit code.

fn check(v: i32) {
    assert v > 0, "v must be positive"
}

fn main() -> i32 {
    check(1)
    check(-1)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: wine, sysroot-x86_64-windows-gnu
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s --target=x86_64-windows-gnu -o %t.exe --cache-dir %t.d
// RUN: { %wine %t.exe 2>&1 || true; } | %FileCheck %s
// CHECK: assertion failed at {{.*}}panic_exit.k:{{[0-9]+}}:{{[0-9]+}}: assert v > 0, "v must be positive"
// RUN: %wine %t.exe 2>/dev/null; test $? -ne 0
