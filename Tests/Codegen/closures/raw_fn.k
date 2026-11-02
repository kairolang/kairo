// The raw function pointer `unsafe fn(A) -> R` (P231): `R(*)(A)` in C++,
// one word, called directly. A named function and a closure that captures
// nothing are raw; either goes into a raw field, variable, parameter,
// result, global or nullable, and a raw value widens to a `fn` value where
// one is wanted. A `var` initialized from a function or a captureless
// closure is the `fn` value, so it can later hold a capturing closure.

import std::io::println

fn twice(v: i32) -> i32 { return v * 2 }

struct Ops { pub var f: unsafe fn(i32) -> i32 }

fn call_raw(o: *Ops, x: i32) -> i32 { return o->f(x) }
fn pick() -> unsafe fn(i32) -> i32 { return twice }
fn take(f: unsafe fn(i32) -> i32) -> i32 { return f(4) }

var global_raw: unsafe fn(i32) -> i32 = twice

fn main() -> i32 {
    var o = Ops { f: twice }
    var g = twice
    var base = 3
    g = fn (v: i32) -> i32 { return v + base }
    var h: unsafe fn(i32) -> i32 = fn (v: i32) -> i32 { return v + 1 }
    var m: (unsafe fn(i32) -> i32)? = null
    if m? { println("unexpected") } else { println("null raw") }
    m = twice
    var w: fn(i32) -> i32 = h
    println(f"field: {call_raw(&o, 2)}")
    println(f"var: {g(1)}")
    println(f"closure: {h(1)}")
    println(f"widened: {w(0)}")
    if m? { println(f"nullable: {m(1)}") }
    println(f"result: {pick()(5)}")
    println(f"param: {take(twice)} {take(fn (v: i32) -> i32 { return v - 1 })}")
    println(f"global: {global_raw(6)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}raw_fn.k
// CXX: template<class S> using __kairo_raw_fn = S *;
// CXX: ::__kairo_raw_fn<signed int(signed int) noexcept> f {
// CXX: ::__kairo_raw_fn<signed int(signed int) noexcept> pick() noexcept;
// CXX: signed int take( ::__kairo_raw_fn<signed int(signed int) noexcept> f) noexcept;
// CXX: ::__kairo_raw_fn<signed int(signed int) noexcept> global_raw = ::{{.*}}::twice;
// CXX: ::__kairo_raw_fn<signed int(signed int) noexcept> h =(+[](signed int v) noexcept->signed int {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      null raw
// OUT-NEXT: field: 4
// OUT-NEXT: var: 4
// OUT-NEXT: closure: 2
// OUT-NEXT: widened: 1
// OUT-NEXT: nullable: 2
// OUT-NEXT: result: 10
// OUT-NEXT: param: 8 3
// OUT-NEXT: global: 12
