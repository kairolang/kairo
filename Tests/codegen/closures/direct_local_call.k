// A local bound to a small closure and never rebound is called as the
// lambda it was made from: `auto __kairo_cl_f = [...](...) {...};` beside the
// `fn` value, and `f(x)` is `__kairo_cl_f(x)`, a direct call. The `fn` value
// is still what is passed, copied and returned. A local that is assigned
// again, one whose address is taken, and one bound to a closure that
// writes its captures are called through the `fn` value, as is the copy a
// nested closure holds.

import std::io::println

@no_inline fn apply(f: fn(i64) -> i64, x: i64) -> i64 {
    return f(x)
}

// Direct: `scale` is never rebound.
@no_inline fn direct(k: i64, n: i64) -> i64 {
    var scale = fn (v: i64) -> i64 { return v * k + 1 }
    var sum: i64 = 0
    for var i: i64 = 0; i < n; i += 1 { sum += scale(i) }
    return sum + apply(scale, 100)
}

// Rebound: the second closure is the one the later calls reach.
@no_inline fn rebound(k: i64) -> i64 {
    var f = fn (v: i64) -> i64 { return v + k }
    var a = f(1)
    f = fn (v: i64) -> i64 { return v * k }
    return a * 100 + f(5)
}

// Its address is taken, and it is rebound through the pointer.
@no_inline fn through_pointer(k: i64) -> i64 {
    var f = fn (v: i64) -> i64 { return v + k }
    var *p = &f
    *p = fn (v: i64) -> i64 { return v - k }
    return f(10)
}

// A closure that writes its capture is not small: called through the value.
@no_inline fn counting() -> i64 {
    var n: i64 = 0
    var next = fn () -> i64 { n += 1; return n }
    next()
    return next()
}

// The nested closure holds its own copy of `add` (a `fn` value, so it is not
// a small closure) and calls that; the outer call of `add` is direct.
@no_inline fn nested(k: i64) -> i64 {
    var add = fn (v: i64) -> i64 { return v + k }
    var twice = fn (v: i64) -> i64 { return add(add(v)) }
    return twice(1) + add(10)
}

fn main() -> i32 {
    println(f"direct: {direct(3, 4)}")
    println(f"rebound: {rebound(4)}")
    println(f"through_pointer: {through_pointer(4)}")
    println(f"counting: {counting()}")
    println(f"nested: {nested(5)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      direct: 323
// OUT-NEXT: rebound: 520
// OUT-NEXT: through_pointer: 6
// OUT-NEXT: counting: 2
// OUT-NEXT: nested: 26

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: direct(signed long k, signed long n) noexcept {
// CXX: auto __kairo_cl_scale =[k](signed long v) noexcept->signed long {
// CXX: auto scale = ::__kairo_fn<signed long(signed long)>::small(__kairo_cl_scale);
// CXX: __kairo_cl_scale(i)
// CXX: apply(scale, 100)
// CXX-LABEL: rebound(signed long k) noexcept {
// CXX-NOT: __kairo_cl_
// CXX: f = ::__kairo_fn<signed long(signed long)>::small([k](signed long v) noexcept->signed long {
// CXX: f(1)
// CXX: f(5)
// CXX-LABEL: through_pointer(signed long k) noexcept {
// CXX-NOT: __kairo_cl_
// CXX: f(10)
// CXX-LABEL: counting() noexcept {
// CXX-NOT: __kairo_cl_
// CXX: own(new auto([n]() mutable noexcept->signed long {
// CXX-LABEL: nested(signed long k) noexcept {
// CXX: auto __kairo_cl_add =[k](signed long v) noexcept->signed long {
// CXX: own(new auto([add](signed long v) mutable noexcept->signed long {
// CXX: add(add(v))
// CXX: twice(1)
// CXX: __kairo_cl_add(10)
