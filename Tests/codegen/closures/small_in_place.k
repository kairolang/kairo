// A closure whose captures are pointers and numbers it never writes is held
// in the `fn` value itself: `__kairo_fn::small(lambda)`, a lambda that
// is not `mutable`, with no allocation. A closure that writes a by-copy
// capture, captures a record, or hands a by-copy capture to a nested
// closure by pointer keeps the heap form (`own(new auto(... mutable ...))`),
// where the capture is the closure's own variable from call to call.
// Either way the closure behaves the same: copies are independent, a
// by-pointer capture writes the original.

import std::io::println

@no_inline fn apply(f: fn(i64) -> i64, x: i64) -> i64 {
    return f(x)
}

@no_inline fn twice(f: fn(), n: i64) {
    for var i: i64 = 0; i < n; i += 1 { f() }
}

// Read-only number capture: in place. `scale` has no allocation at -O2.
@no_inline fn scale(k: i64, x: i64) -> i64 {
    return apply(fn (v: i64) -> i64 { return v * k + 1 }, x)
}

// By pointer: the capture is a pointer the body only reads; in place.
@no_inline fn tally(n: i64) -> i64 {
    var acc: i64 = 0
    twice(fn ()|*| { *acc += 2 }, n)
    return acc
}

// Writes its own copy: heap, mutable.
@no_inline fn counter(start: i64) -> i64 {
    var next = fn () -> i64 { start += 1; return start }
    next()
    var other = next
    other()
    return next() * 100 + other()
}

// A record capture: heap.
@no_inline fn greet(name: string) -> usize {
    var f = fn () -> usize { return name.size() }
    return f()
}

// The nested closure takes the outer closure's copy by pointer: the outer
// copy is written, so the outer closure is heap and mutable.
@no_inline fn nested(seed: i64) -> i64 {
    var outer = fn () -> i64 {
        var bump = fn ()|*seed| { *seed += 5 }
        bump()
        return seed
    }
    outer()
    return outer()
}

// Many number captures: still `small`; past one word it is held on the
// heap, copied bitwise.
@no_inline fn wide(a: i64, b: i64, c: i64) -> i64 {
    var f = fn (x: i64) -> i64 { return x + a + b * c }
    var g = f
    return f(1) + g(2)
}

fn main() -> i32 {
    println(f"scale: {scale(3, 5)}")
    println(f"tally: {tally(4)}")
    println(f"counter: {counter(10)}")
    var who = "kairo"
    println(f"greet: {greet(who)}")
    println(f"nested: {nested(1)}")
    println(f"wide: {wide(1, 2, 3)}")
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
// OUT:      scale: 16
// OUT-NEXT: tally: 8
// OUT-NEXT: counter: 1213
// OUT-NEXT: greet: 5
// OUT-NEXT: nested: 11
// OUT-NEXT: wide: 17

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: ::small([k](signed long v) noexcept->signed long {
// CXX: ::small([acc = & acc]() noexcept->void {
// CXX: own(new auto([start]() mutable noexcept->signed long {
// CXX: own(new auto([name = static_cast<{{.*}}string &&>(name)]() mutable noexcept->decltype(sizeof(0)) {
// CXX: own(new auto([seed]() mutable noexcept->signed long {
// CXX: auto __kairo_cl_bump =[seed = & seed]() noexcept->void {
// CXX: auto __kairo_cl_f =[a, b, c](signed long x) noexcept->signed long {

// The in-place closure costs no allocation: `scale` and `tally` call neither
// operator new nor the global allocator.
// RUN: rm -rf %t.ll.d
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --cache-dir %t.ll.d
// RUN: %FileCheck %s --check-prefix=IR < %t.ll.d/small_in_place.ll
// IR-LABEL: define {{.*}}5scale{{.*}}(
// IR-NOT: call {{.*}}@_Zn
// IR-NOT: call {{.*}}alloc
// IR-LABEL: define {{.*}}5tally{{.*}}(
// IR-NOT: call {{.*}}@_Zn
// IR-NOT: call {{.*}}alloc
// IR-LABEL: define {{.*}}7counter{{.*}}(
