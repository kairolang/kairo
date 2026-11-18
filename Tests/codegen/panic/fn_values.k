// `fn` values that may panic (PANIC.md §2.10, §4.1): a closure with a
// declared set returns its panic result from the lambda; a call through a
// `fn` value is held and tested like any call; a function whose set is the
// type's passes as it is; one whose set is smaller, or that does not panic,
// is wrapped (EmitIR::_fn_effect_value), its result forwarded or made Ok.
struct E { var code: i32 }
fn g(n: i32) panic(E) -> i32 { if n < 0 { panic E { code: n } } return n }
fn run(f: fn(i32) panic(E) -> i32, n: i32) panic(E) -> i32 { return f(n) + 1 }
fn main_a() -> i32 {
    var c = fn (n: i32) panic(E) -> i32 { if n == 3 { panic E { code: 33 } } return n * 2 }
    var a = try run(c, 3) catch e: E => e.code
    var b = try run(g, -4) catch e: E => e.code
    var d = try c(5) catch => 0
    if a != 33 { return 1 }
    if b != -4 { return 2 }
    if d != 10 { return 3 }
    return 0
}
struct F2 { var code: i32 }
fn plain(n: i32) -> i32 { return n * 3 }
fn onlye(n: i32) panic(E) -> i32 { if n < 0 { panic E { code: n } } return n }
fn run2(f: fn(i32) panic(E, F2) -> i32, n: i32) panic(E, F2) -> i32 { return f(n) }
var hits: i32 = 0
fn vplain(n: i32) { hits = hits + n }
fn run3(f: fn(i32) panic(E), n: i32) panic(E) { f(n) }
fn main_b() -> i32 {
    var a = try run2(plain, 2) catch => 0
    var b = try run2(onlye, -2) catch e: E => e.code catch => 0
    var c2 = fn (n: i32) panic(E) -> i32 { if n < 0 { panic E { code: 5 } } return n }
    var c = try run2(c2, -1) catch e: E => e.code catch => 0
    try { run3(vplain, 4) } catch { return 4 }
    if a != 6 { return 1 }
    if b != -2 { return 2 }
    if c != 5 { return 3 }
    if hits != 4 { return 5 }
    return 0
}

fn main() -> i32 {
    if main_a() != 0 { return 10 + main_a() }
    if main_b() != 0 { return 20 + main_b() }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s
// The closure's lambda returns the result; the widening is a wrapper.
// CHECK: ::__kairo_fn<{{.*}}Panic<signed int,{{.*}}>(signed int)>
// CHECK: ::__kairo_pcall<
