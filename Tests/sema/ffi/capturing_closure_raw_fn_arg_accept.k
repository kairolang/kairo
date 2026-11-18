// A closure that captures nothing, and a named function, are accepted where
// a raw `unsafe fn` is expected (a C comparator such as qsort's).

ffi "c" import "stdlib.h"

fn take(f: unsafe fn(i32) -> i32) -> i32 { return 0 }
fn named(a: i32) -> i32 { return a }

fn main() -> i32 {
    var arr: [i32; 3] = [3, 1, 2]
    unsafe {
        qsort(&arr as unsafe *void, 3, 4, fn (a: unsafe *const void, b: unsafe *const void) -> i32 { return 0 })
    }
    return take(fn (a: i32) -> i32 { return a + 1 }) + take(named)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not="error [" --implicit-check-not="I003E"
