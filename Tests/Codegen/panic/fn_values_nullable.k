// A `fn` value converted to a NULLABLE `fn` type with a wider panic set
// (P167): EmitIR::_fn_effect_value looks through the `?`, so the value is
// wrapped as it is for a plain `fn` target and the wrapper becomes the
// Nullable. Before, the target was not seen and the C++ step failed ("no
// matching conversion for static_cast ... to Nullable<__kairo_fn<...>>").
// Covered: a function that does not panic and one with a smaller set, as
// an argument, an initializer and an assignment, and a nullable source
// into a wider nullable target, null and not.
struct E { var code: i32 }
struct F2 { var code: i32 }
fn plain(n: i32) -> i32 { return n * 3 }
fn onlye(n: i32) panic(E) -> i32 { if n < 0 { panic E { code: n } } return n }
fn run(f: (fn(i32) panic(E, F2) -> i32)?, n: i32) panic(E, F2) -> i32 {
    if f? { return f(n) }
    return -100
}
fn main() -> i32 {
    var a = try run(plain, 2) catch => 0
    var b = try run(onlye, -2) catch e: E => e.code catch => 0
    var g: (fn(i32) panic(E, F2) -> i32)? = null
    var c = try run(g, 1) catch => 0
    g = onlye
    var d = try run(g, 7) catch => 0
    var h: (fn(i32) panic(E) -> i32)? = onlye
    var k: (fn(i32) panic(E, F2) -> i32)? = h
    var e1 = try run(k, -5) catch e: E => e.code catch => 0
    var hn: (fn(i32) panic(E) -> i32)? = null
    var kn: (fn(i32) panic(E, F2) -> i32)? = hn
    var e2 = try run(kn, 1) catch => 0
    if a != 6 { return 1 }
    if b != -2 { return 2 }
    if c != -100 { return 3 }
    if d != 7 { return 4 }
    if e1 != -5 { return 5 }
    if e2 != -100 { return 6 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s
// The plain value is wrapped; the nullable source is tested, then wrapped.
// CHECK: run( ::__kairo_fn<{{.*}}>::own(new auto([__kairo_w = ::__kairo_fn<signed int(signed int)>(
// CHECK: k =[](auto && __kairo_h) noexcept-> ::builtin::Nullable<
// CHECK-NEXT: if(__kairo_h.is_null()) {
