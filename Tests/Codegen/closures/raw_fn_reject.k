// What cannot become a raw `unsafe fn`: a closure that captures,
// and a `fn` value, which may hold one. Both are SC001E where they are
// converted -- an initializer, an argument, a C function pointer parameter
// (an imported C pointer is raw), a field -- instead of the run-time trap
// the `fn` value's conversion to `R(*)(A)` would be.

ffi "c" import "c_callback.h"

struct Ops { pub var f: unsafe fn(i32) -> i32 }

fn take(f: unsafe fn(i32) -> i32) -> i32 { return f(4) }

fn main() -> i32 {
    var k = 3
    var a: unsafe fn(i32) -> i32 = fn (v: i32) -> i32 { return v + k }
    var value: fn(i32) -> i32 = fn (v: i32) -> i32 { return v }
    var b: unsafe fn(i32) -> i32 = value
    var c = take(fn (v: i32) -> i32 { return v * k })
    var d = c_apply(value, 1)
    var o = Ops { f: value }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: raw_fn_reject.k:15:36: error [SC258E]: cannot convert 'fn (i32) -> i32' to the raw 'unsafe fn (i32) -> i32': this closure captures, so it has no function pointer
// CHECK: raw_fn_reject.k:17:36: error [SC258E]: cannot convert 'fn (i32) -> i32' to the raw 'unsafe fn (i32) -> i32': a 'fn' value may hold a capturing closure, which has no function pointer
// An argument is ranked by overload resolution, which says the same in its note.
// CHECK: raw_fn_reject.k:18:13: error [SC063E]: no matching overload for call to 'take'
// CHECK: raw_fn_reject.k:11:1: note [I900N]: candidate not viable: cannot convert argument of type 'fn (i32) -> i32' to parameter 'f' of type 'unsafe fn (i32) -> i32'
// CHECK: raw_fn_reject.k:19:13: error [SC063E]: no matching overload for call to 'c_apply'
// CHECK: c_callback.h:3:1: note [I900N]: candidate not viable: cannot convert argument of type 'fn (i32) -> i32' to parameter 'f' of type 'unsafe fn (i32) -> i32'
// CHECK: raw_fn_reject.k:20:22: error [SC258E]: cannot convert 'fn (i32) -> i32' to the raw 'unsafe fn (i32) -> i32': a 'fn' value may hold a capturing closure, which has no function pointer
