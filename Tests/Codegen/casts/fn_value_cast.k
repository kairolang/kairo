// `f as fn(...)` from a named function: a named function is its raw
// `unsafe fn` pointer, which widens to the `fn` value of its signature
// implicitly (type-system.mdx), and the cast spells that same conversion.
// It was SC027E ("no conversion") while `var f: fn(i32) -> i32 = twice` was
// accepted. Into a slot that already takes the raw pointer it is redundant
// (SC031W); a cast of a non-panicking function into a panicking `fn` type is
// the effect widening, also implicit. The reverse, a `fn` value as the raw
// `unsafe fn`, stays refused (Tests/Sema/ExprTyper/fn_value_cast_errors.k).
struct E { var c: i32 }

fn twice(v: i32) -> i32 { return v * 2 }
fn add(a: i32, b: i32) -> i32 { return a + b }

fn call(f: fn(i32) -> i32, v: i32) -> i32 { return f(v) }

fn main() -> i32 {
    var f = twice as fn(i32) -> i32
    var g: fn(i32) -> i32 = twice as fn(i32) -> i32
    var h = add as fn(i32, i32) -> i32
    var p = twice as fn(i32) panic(E) -> i32
    var r = f(1) + g(2) + h(3, 4) + call(twice as fn(i32) -> i32, 5)
    return r                                    // 2 + 4 + 7 + 10 == 23
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: fn_value_cast.k:18:29: warning [SC031W]: redundant cast: 'unsafe fn (i32) -> i32' converts to 'fn (i32) -> i32' implicitly
// DIAG: fn_value_cast.k:21:42: warning [SC031W]: redundant cast: 'unsafe fn (i32) -> i32' converts to 'fn (i32) -> i32' implicitly

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: ::__kairo_fn<signed int(signed int)> f = static_cast< ::__kairo_fn<signed int(signed int)>>( {{.*}}twice);
// CXX: p = ::__kairo_fn< ::builtin::errors::panic_result::Panic<signed int, {{.*}}E>(signed int)>::own(new auto([__kairo_w = ::__kairo_fn<signed int(signed int)>( {{.*}}twice)]

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 23
