// The calling convention is part of a function's type and of `fn(...)`
// types: `fn(A) @preserve_most -> R`. A function converts only to a type
// with its own convention, either way; across conventions is SC028E with
// both named. Such a type is always raw: only a named function holds it.

@preserve_most
priv fn slow(n: u64) -> u64 { return n }

@preserve_all
priv fn slow_all(n: u64) -> u64 { return n }

priv fn plain(n: u64) -> u64 { return n }

fn main() -> i32 {
    var a: fn(u64) @preserve_most -> u64 = slow
    var b: fn(u64) -> u64 = slow
    var c: fn(u64) @preserve_most -> u64 = plain
    var d: fn(u64) @preserve_most -> u64 = slow_all
    var e: unsafe fn(u64) -> u64 = slow
    var g = slow
    var h: fn(u64) @preserve_most -> u64 = g
    return (a(1) + h(1)) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --target=x86_64-linux-gnu 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK-DAG: callconv_fn_type.k:16:{{[0-9]+}}: error [SC028E]: cannot convert 'fn (u64) @preserve_most -> u64' to 'fn (u64) -> u64': the calling conventions differ
// CHECK-DAG: callconv_fn_type.k:16:{{[0-9]+}}: note [I900N]: the value has '@preserve_most'; the target type has the default calling convention
// CHECK-DAG: callconv_fn_type.k:17:{{[0-9]+}}: error [SC028E]: cannot convert 'unsafe fn (u64) -> u64' to 'fn (u64) @preserve_most -> u64': the calling conventions differ
// CHECK-DAG: callconv_fn_type.k:17:{{[0-9]+}}: note [I900N]: the value has the default calling convention; the target type has '@preserve_most'
// CHECK-DAG: callconv_fn_type.k:18:{{[0-9]+}}: error [SC028E]: cannot convert 'fn (u64) @preserve_all -> u64' to 'fn (u64) @preserve_most -> u64': the calling conventions differ
// CHECK-DAG: callconv_fn_type.k:19:{{[0-9]+}}: error [SC028E]: cannot convert 'fn (u64) @preserve_most -> u64' to 'unsafe fn (u64) -> u64': the calling conventions differ
