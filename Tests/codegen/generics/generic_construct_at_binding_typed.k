// A binding initialised from `__builtin_construct_at<T>(...)` inside a generic
// body has the pointer type of T at every instantiation: no I011W "no inferred
// type", and the constructed value reads back through the binding.

fn <T> mk(buf: unsafe *u8) -> T {
    var p = __builtin_construct_at<T>(buf, 42)
    return *p
}
fn main() -> i32 {
    var buf: u64 = 0
    var v: i32 = 0
    unsafe { v = mk<i32>(&buf as unsafe *u8) }
    return v - 42
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe; test $? -eq 0
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d/o2
// RUN: %t.exe; test $? -eq 0
