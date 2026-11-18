// A `-> !` function whose last act is a call through a `fn(i32) -> !`
// value is emitted `(f(code), __builtin_unreachable())`, so the C++
// compiler sees no path out of the [[noreturn]] function and warns nothing.
// The program builds at -O0 and -O2 without a warning and exits 0 (the
// never-returning path is not taken).

fn die(code: i32) -> ! { while true { } }

static handler: fn(i32) -> ! = die

fn stop(code: i32) -> ! {
    handler(code)
}

fn main() -> i32 {
    if false { stop(1) }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s
// CHECK: ( ::never_fn_value_call::handler(code), __builtin_unreachable());
// RUN: { %kairo %s -O2 -o %t.warn.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=QUIET --allow-empty
// QUIET-NOT: warning
// QUIET-NOT: error
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
// RUN: rm -rf %t.d2 %t2.exe
// RUN: %kairo %s -O2 -o %t2.exe --cache-dir %t.d2
// RUN: %t2.exe; test $? -eq 0
