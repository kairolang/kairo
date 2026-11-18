// A capturing closure passed where a raw `unsafe fn` is expected (a C
// function pointer such as qsort's comparator) says why in the candidate's
// note, as SC258E says it for a declaration's initializer: a closure that
// captures has no function pointer. The note only said the types differ.

ffi "c" import "stdlib.h"

fn take(f: unsafe fn(i32) -> i32) -> i32 { return 0 }

fn main() -> i32 {
    var k = 3
    var arr: [i32; 3] = [3, 1, 2]
    unsafe {
        qsort(&arr as unsafe *void, 3, 4, fn (a: unsafe *const void, b: unsafe *const void) -> i32 { return k })
    }
    var v: fn(i32) -> i32 = fn (a: i32) -> i32 { return a + k }
    return take(fn (a: i32) -> i32 { return a + k }) + take(v)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK:      capturing_closure_raw_fn_arg.k:14:9: error [SC063E]: no matching overload for call to 'qsort'
// CHECK-NEXT: note [I900N]: candidate not viable: cannot convert argument of type 'fn (unsafe *const void, unsafe *const void) -> i32' to parameter '{{.*}}' of type 'unsafe fn {{.*}}; this closure captures, so it has no function pointer: only a named function or a closure that captures nothing is a raw 'unsafe fn'
// CHECK:      capturing_closure_raw_fn_arg.k:17:12: error [SC063E]: no matching overload for call to 'take'
// CHECK-NEXT: capturing_closure_raw_fn_arg.k:8:1: note [I900N]: candidate not viable: {{.*}}; this closure captures, so it has no function pointer
// CHECK:      capturing_closure_raw_fn_arg.k:17:56: error [SC063E]: no matching overload for call to 'take'
// CHECK-NEXT: capturing_closure_raw_fn_arg.k:8:1: note [I900N]: candidate not viable: {{.*}}; a 'fn' value may hold a capturing closure, which has no function pointer
