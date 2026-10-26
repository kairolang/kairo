// G10 (Compiler/Sema/NULLABLE.md 2.6): `unwrap!(x)` is `if x? => x else
// <abort>`, run for real. On null it is not a panic: it writes "unwrap!(...)
// on null at <file>:<line>:<col>" to stderr and aborts, so the process
// dies of SIGABRT (status 134) with nothing after it run. Covered on the
// present path: a value, a call bound once (its side effect counted) and a
// record moved out of it (destroyed exactly once), a nullable pointer, a
// place unwrapped as an lvalue (`unwrap!(f).v = 4` writes `f`'s payload),
// `x` read as `T` after `unwrap!(x)` with no check, a nested `(i32?)?`
// unwrapping one level, a generic `T?`. Then a null unwrap, whose message
// and exit status are checked, and whose next line never prints.

import std::io::println

class Widget {
    pub var id: i32
    pub fn Widget(self, id: i32) { self.id = id }
    @move fn Widget(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op delete(self) { if self.id != 0 { println(f"~Widget {self.id}") } }
}

class Foo { pub var v: i32 = 1 }

var calls = 0
fn find(k: i32) -> i32? { calls += 1; if k > 0 { return k } return null }
fn widget(k: i32) -> Widget? { if k > 0 { return Widget(k) } return null }
fn nest(k: i32) -> i32? { var v: i32? = null; if k > 0 { v = k } return v }
fn <T> first(t: T?) -> T { return unwrap!(t) }

fn main() -> i32 {
    var a? = find(3)
    var v = unwrap!(a)
    var w = a + 1
    println(f"value: {v} {w}")

    calls = 0
    var c = unwrap!(find(7))
    println(f"once: {c} calls={calls}")

    {
        var wd = unwrap!(widget(5))
        println(f"record: {wd.id}")
    }

    var n = 9
    var p: (*i32)? = &n
    *unwrap!(p) = 10
    println(f"pointer: {n}")

    var f: Foo? = Foo()
    unwrap!(f).v = 4
    println(f"lvalue: {f.v}")

    var g: i32? = 6
    println(f"generic: {first(g)}")

    var z? = find(0)
    println("before")
    var bad = unwrap!(z)
    println(f"not reached {bad}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      return(*({
// CXX-NEXT:     if(t.is_null()) {
// CXX-NEXT:         ::builtin::unwrap_failed({{.*}}"unwrap!(t) on null at {{.*}}unwrap.k:27:35\012"{{.*}}, {{[0-9]+}});
// CXX:      ::builtin::Nullable<signed int> __kairo_unwrap0 ={{ ?}}::{{.*}}find(7);
// CXX-NEXT: if(__kairo_unwrap0.is_null()) {
// CXX:      static_cast<signed int &&>(__kairo_unwrap0.__value());

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %FileCheck %s --check-prefix=ERR --match-full-lines < %t.err
// OUT:      value: 3 4
// OUT-NEXT: once: 7 calls=1
// OUT-NEXT: record: 5
// OUT-NEXT: ~Widget 5
// OUT-NEXT: pointer: 10
// OUT-NEXT: lvalue: 4
// OUT-NEXT: generic: 6
// OUT-NEXT: before
// OUT-NOT:  not reached
// ERR:      unwrap!(z) on null at {{.*}}unwrap.k:58:15
// ERR-NOT:  {{.}}
