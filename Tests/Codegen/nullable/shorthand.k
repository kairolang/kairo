// G4 (Compiler/Sema/NULLABLE.md 1.6): `var x? = e` end to end. Each binding
// is the ::builtin::Nullable of its initializer's type, one level (a `T?`
// initializer is not wrapped again), and holds the value it was given:
// a present Widget is destroyed exactly once, at reassignment, at `= null`
// or at scope exit, and a moved-in Widget leaves its source empty. No null
// test exists before G5, so nothing reads a value back here; what runs is
// the declaration, its conversions and its lifecycle.
// The once-rule is decided when the body is typed: in a generic body
// `var x? = t` is `T?`, so `T = i32?` gives `(i32?)?` (substitution never
// collapses, NULLABLE.md 1.5). A destructuring binder `(a?, b)` shares the
// rule: `a` from an `i32?` element is `i32?`.

import std::io::println

class Widget {
    pub var id: i32
    pub fn Widget(self, id: i32) { self.id = id }
    @move fn Widget(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op delete(self) { if self.id != 0 { println(f"~Widget {self.id}") } }
}

struct P { var x: i32 = 1 }

fn find(k: i32) -> i32? {
    if k > 0 { return k }
    return null
}
fn make(id: i32) -> Widget? { return Widget(id) }
fn count(v: i32?) -> i32 { return 1 }
fn <T> gen(t: T) -> i32 { var x? = t; return 1 }
fn pair() -> (i32?, i32) { return (find(2), 2) }

var g? = 4

fn main() -> i32 {
    var a? = 10
    const b? = find(3)
    var n = 7
    var c? = &n
    var s? = P{}
    a = null
    a = 11
    c = null
    var (pa?, pb) = pair()
    var r = count(a) + count(b) + count(g) + gen(5) + gen(b)   // 5
    {
        var w? = Widget(1)
        w = Widget(2)                            // ~Widget 1
        println("reassigned")
        w = null                                 // ~Widget 2
        println("cleared")
        var m? = make(3)                         // Widget?, not (Widget?)?
        var mv = Widget(4)
        var t? = mv                              // moved: mv is empty
    }                                            // ~Widget 4, ~Widget 3
    println("done")
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      template<class T> signed int gen(T t) noexcept {
// CXX-NEXT:     ::builtin::Nullable<T> x = t;
// CXX:      ::builtin::Nullable<signed int> g = static_cast< ::builtin::Nullable<signed int>>(4);
// CXX:      ::builtin::Nullable<signed int> a = static_cast< ::builtin::Nullable<signed int>>(10);
// CXX:      const{{ ?}}::builtin::Nullable<signed int> b = {{.*}}find(3);
// CXX:      ::builtin::Nullable<signed int *> c =
// CXX:      ::builtin::Nullable< {{.*}}shorthand::P> s =
// CXX:      ::builtin::Nullable<signed int> pa = __kairo_tup{{[0-9]+}}._0;
// CXX:      ::builtin::Nullable< {{.*}}shorthand::Widget> m = {{.*}}make(3);
// CXX-NOT:  Nullable<{{ ?}}::builtin::Nullable

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out; test $? -eq 5
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      ~Widget 1
// OUT-NEXT: reassigned
// OUT-NEXT: ~Widget 2
// OUT-NEXT: cleared
// OUT-NEXT: ~Widget 4
// OUT-NEXT: ~Widget 3
// OUT-NEXT: done
