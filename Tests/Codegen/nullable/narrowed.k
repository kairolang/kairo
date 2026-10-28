// G16 (Compiler/Sema/NULLABLE.md §4, §5 step 3): every read the nullness
// analysis narrowed is the Nullable's UNCHECKED `__value()` in C++
// (NarrowedAccessLowering), and runs. Covered: a value `i32?` in operators,
// `+=` both ways and a `T` parameter; a nullable pointer through `*p` and
// `p->m()`; a record through `.f` and a method; WRITING through a narrowed
// record (`a.v = 3` writes the nullable's payload, `__value()` is `T&`);
// a field path `o.cache.v` read and written; two nullable levels in one
// path (`s.mid.inner.w`); `self.cache` in a method; a `const` nullable
// (`const T& __value() const`); a move-only payload passed by value
// (CopyMoveLowering's move of a narrowed `w` is a move of the VALUE,
// `static_cast<Widget&&>(w.__value())`, and the payload dies once); a
// global between its check and the next call; early exits; `while x?`;
// the `if a? => a else => 0` expression; a generic `T?`. Each check
// prints, so a wrong value shows which one.

import std::io::println

class Foo {
    pub var v: i32
    pub fn Foo(self, v: i32) { self.v = v }
    pub fn get(self) -> i32 { return self.v }
}

class In { pub var w: i32 = 2 }
class Mid { pub var inner: In? = null; pub fn Mid(self) { } }
struct S { pub var mid: Mid? = null; pub var cache: Foo? = null; }

class Box {
    pub var cache: i32? = null
    pub fn Box(self) { }
    pub fn get(self) -> i32 {
        if self.cache? { return self.cache }
        return -1
    }
}

class Widget {
    pub var id: i32
    pub fn Widget(self, id: i32) { self.id = id }
    @move fn Widget(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op delete(self) { if self.id != 0 { println(f"~Widget {self.id}") } }
}

var g: i32? = 40

fn find(k: i32) -> i32? { if k > 0 { return k } return null }
fn take(x: i32) -> i32 { return x }
fn sink(w: Widget) -> i32 { return w.id }
fn <T> first(t: T?, d: T) -> T { if t? { return t } return d }

fn deref(p: (*i32)?) -> i32 {
    if !p? { return 0 }
    return *p
}

fn call(p: (*Foo)?) -> i32 {
    if p? { return p->get() }
    return 0
}

fn glob() -> i32 {
    if g? { return g + 2 }
    return 0
}

fn main() -> i32 {
    var a? = find(5)
    if a? {
        var r = 0
        r += a
        var b? = 1
        b += a
        println(f"value: {a + 1} {r} {b} {take(a)}")
    }

    var n = 8
    var foo = Foo(3)
    println(f"pointer: {deref(&n)} {call(&foo)}")

    var f: Foo? = Foo(4)
    if f? {
        f.v = 6
        println(f"record: {f.v} {f.get()}")
    }

    var o = S()
    o.cache = Foo(1)
    o.cache.v = 9
    o.mid = Mid()
    o.mid.inner = In()
    o.mid.inner.w = 11
    println(f"path: {o.cache.v} {o.cache.get()} {o.mid.inner.w}")

    var bx = Box()
    bx.cache = 12
    const c: i32? = 13
    if c? { println(f"method/const: {bx.get()} {c}") }

    var w: Widget? = Widget(7)
    if w? { println(f"moved: {sink(w)}") }
    println("after sink")

    println(f"global: {glob()}")

    var sum = 0
    var it? = find(3)
    while it? {
        sum += it
        it = find(it - 1)
    }
    var z? = find(0)
    var v1 = if a? => a else => 0
    var v2 = if z? => z else => 100
    println(f"flow: {sum} {v1} {v2} {first(a, 0)} {first(z, 50)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      if((!t.is_null())) {
// CXX-NEXT:     return t.__value();
// CXX:      return(* p.__value());
// CXX:      return p.__value()->get();
// CXX:      return( ::narrowed::g.__value() + 2);
// CXX:      (r += a.__value());
// CXX:      (b.__value() += a.__value());
// CXX:      (f.__value().v = 6);
// CXX:      (o.cache.__value().v = 9);
// CXX:      (o.mid.__value().inner.__value().w = 11);
// CXX:      static_cast< ::narrowed::Widget &&>(w.__value())
// CXX-NOT:  static_cast< ::builtin::Nullable< ::narrowed::Widget> &&>

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      value: 6 5 6 5
// OUT-NEXT: pointer: 8 3
// OUT-NEXT: record: 6 6
// OUT-NEXT: path: 9 9 11
// OUT-NEXT: method/const: 12 13
// OUT-NEXT: ~Widget 7
// OUT-NEXT: moved: 7
// OUT-NEXT: after sink
// OUT-NEXT: global: 42
// OUT-NEXT: flow: 6 5 100 5 50
