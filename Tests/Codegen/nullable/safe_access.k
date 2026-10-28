// G9 (Compiler/Sema/NULLABLE.md 2.5): `x?.m` is `if x? => x.m else null`,
// `x?.f(args)` the same with the call AND its arguments on the non-null
// path only, `?->` the same over a nullable pointer, and a chain tests
// each step on the previous one left to right (CoalesceLowering). Covered:
// a field and a method on a present and a null receiver, with an argument
// whose side effect is counted (it never runs on null); a member that is
// itself nullable (the result is `M?`, not `(M?)?`); a `void` method (a
// statement); `?->` on a field and a method; a chain three and four deep
// through `?->`; two `?.` steps through a nullable field; a call on the
// left bound once (its count); `?.` after a `?.` call; the result in `??`;
// a generic `b?.val` / `b?.get()`. Each line prints, so a wrong value
// shows which case broke.

import std::io::println

var calls = 0
fn arg(k: i32) -> i32 { calls += 1; return k }

class Inner { pub var w: i32 = 7; pub var tag: i32? = null }

class Foo {
    pub var v: i32
    pub var n: i32? = null
    pub var inner: Inner? = null
    pub var next: (*Foo)? = null
    pub fn Foo(self, v: i32) { self.v = v }
    pub fn get(self, k: i32) -> i32 { return self.v + k }
    pub fn maybe(self) -> i32? { return self.n }
    pub fn bump(self) { self.v += 1 }
    pub fn me(self) -> Foo? { return Foo(self.v * 10) }
}

class <T> Box {
    pub var val: T
    pub fn Box(self, v: T) { self.val = v }
    pub fn get(self) -> T { return self.val }
}
fn <T> peek(b: Box<T>?) -> T? { return b?.val }
fn <T> call(b: Box<T>?) -> T? { return b?.get() }

fn mk(k: i32) -> Foo? { calls += 1; if k > 0 { return Foo(k) } return null }

fn main() -> i32 {
    var f: Foo? = Foo(3)
    var z: Foo? = null
    calls = 0
    var a? = f?.v
    var b? = f?.get(arg(2))
    var c? = z?.get(arg(2))
    println(f"field/method: {a ?? -1} {b ?? -1} {c ?? -1} calls={calls}")

    var d? = f?.maybe()
    var e? = f?.n
    println(f"nullable member: {d?} {e?}")

    f?.bump()
    z?.bump()
    println(f"void: {f?.v ?? -1}")

    var x = Foo(1)
    var y = Foo(2)
    var w = Foo(3)
    x.next = &y
    y.next = &w
    var p: (*Foo)? = &x
    var q: (*Foo)? = &null
    println(f"arrow: {p?->v ?? -1} {q?->v ?? -1} {p?->next?->next?->v ?? -1} {p?->next?->next?->next?->v ?? -1}")
    calls = 0
    println(f"arrow call: {p?->get(arg(1)) ?? -1} {q?->get(arg(1)) ?? -1} calls={calls}")
    p?->bump()
    q?->bump()
    println(f"arrow void: {x.v}")

    f.inner = Inner()
    println(f"deep: {f?.inner?.w ?? -1} {z?.inner?.w ?? -1} {f?.inner?.tag ?? -2}")

    calls = 0
    println(f"once: {mk(4)?.v ?? -1} {mk(0)?.v ?? -1} {mk(5)?.me()?.v ?? -1} calls={calls}")

    var bx: Box<i32>? = Box<i32>(4)
    var bn: Box<i32>? = null
    var gp? = peek(bx)
    var gq? = call(bx)
    var gr? = call(bn)
    println(f"generic: {gp ?? 0} {gq ?? 0} {gr ?? 0}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      a =((!f.is_null()) ? static_cast<{{ ?}}::builtin::Nullable<signed int>>(f.__value().v):
// CXX:      d =((!f.is_null()) ? f.__value().maybe():
// CXX:      if((!f.is_null())) {
// CXX-NEXT:     f.__value().bump();
// CXX:      ((((!p.is_null()) &&(!p.__value()->next.is_null())) &&(!p.__value()->next.__value()->next.is_null())) ? static_cast<{{ ?}}::builtin::Nullable<signed int>>(p.__value()->next.__value()->next.__value()->v):
// CXX:      (((!f.is_null()) &&(!f.__value().inner.is_null())) ? static_cast<{{ ?}}::builtin::Nullable<signed int>>(f.__value().inner.__value().w):
// CXX:      ::builtin::Nullable<{{.*}}Foo> __kairo_safe{{[0-9]+}} ={{ ?}}::{{.*}}mk(4);
// CXX-NOT:  ?.

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      field/method: 3 5 -1 calls=1
// OUT-NEXT: nullable member: false false
// OUT-NEXT: void: 4
// OUT-NEXT: arrow: 1 -1 3 -1
// OUT-NEXT: arrow call: 2 -1 calls=1
// OUT-NEXT: arrow void: 2
// OUT-NEXT: deep: 7 -1 -2
// OUT-NEXT: once: 4 -1 50 calls=3
// OUT-NEXT: generic: 4 4 0
