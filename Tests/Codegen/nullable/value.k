// NULLABLE.md G3: every `T?` is ::builtin::Nullable<T> in C++, and every
// implicit conversion into one is a constructor of it: a value becomes the
// present Nullable, `null` (and `&null` against a nullable pointer, 1.3)
// the null one. Covered sites: local initialisers, assignment both ways,
// return, arguments (a `T` and `null`), a default argument, field
// initialisers, if-expression arms (one arm `null`), `(*i32)?`, `(i32?)?`.
// No null test or narrowing exists yet (G5+), so nothing reads a nullable
// back: the exit code sums non-nullable results, and the payload's
// lifecycle is observed through Widget's destructor, which prints for a
// live Widget only (a moved-from one has id 0). A null `Widget?` holds no
// Widget; a present one is destroyed exactly once -- on reassignment, on
// `= null`, at scope exit; a move-only Widget moves into a `Widget?`
// parameter. Regression for the ticket "NullableTypeLowering is never
// run": every `T?` here used to ICE in CXXSpell.

import std::io::println

class Widget {
    pub var id: i32
    pub fn Widget(self, id: i32) { self.id = id }
    @move fn Widget(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op delete(self) { if self.id != 0 { println(f"~Widget {self.id}") } }
}

class Cp {
    pub var id: i32
    pub fn Cp(self, id: i32) { self.id = id }
}

class Holder {
    var cache: Widget? = null
    var n: i32? = 3
    pub fn Holder(self) { }
    pub fn fill(self, id: i32) { self.cache = Widget(id) }
    pub fn clear(self) { self.cache = null }
}

class <T> Box {
    pub var v: T? = null
    pub fn Box(self) { }
    pub fn set(self, x: T) { self.v = x }
}

fn find(n: i32) -> i32? {
    if n > 0 { return n }
    return null
}

fn make(id: i32) -> Widget? {
    if id == 0 { return null }
    return Widget(id)
}

fn <T> same(x: T?) -> T? { return x }
fn take(w: Widget?) -> i32 { return 1 }
fn opt(x: usize? = null) -> i32 { return 2 }
fn pick(c: bool) -> i32? { return if c => 5 else => null }
fn ptr(p: (*i32)?) -> i32 { return 4 }
fn wide(x: i64?) -> i32 { return 8 }

fn main() -> i32 {
    var a: i32? = 5
    a = null
    a = 7
    var b = find(3)
    var c = find(-1)
    var u: i32?
    var x: i32 = 9
    var r = take(null) + opt() + opt(4) + ptr(&x) + ptr(null) + ptr(&null) + wide(x)    // 25
    var p = pick(true)
    var q = pick(false)
    var g = same(b)
    var bx = Box<i32>()
    bx.set(4)
    println("widgets")
    {
        var w = make(1)
        var z = make(0)                 // null: no Widget
        w = make(2)                     // ~Widget 1
        println("reassigned")
        w = null                        // ~Widget 2
        println("cleared")
        var m = Widget(3)
        r += take(m)                    // moved in; ~Widget 3 when the parameter dies
        println("taken")
        var cp = Cp(1)
        var cq: Cp? = cp                // a copy
        var last = make(4)
    }                                   // ~Widget 4
    println("holder")
    {
        var h = Holder()
        h.fill(5)
        h.fill(6)                       // ~Widget 5
        h.clear()                       // ~Widget 6
        h.fill(7)
    }                                   // ~Widget 7
    var nn: (i32?)? = null
    var ni: i32? = 1
    var nested: (i32?)? = ni
    println("done")
    return r                            // 26
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: error
// DIAG: value.k:98:19: warning [S055W]: nested nullable
// DIAG-NOT: error
// DIAG: value.k:100:23: warning [S055W]: nested nullable
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}value.k
// CXX:      ::builtin::Nullable< ::value::Widget> cache = __kairo_init_cache();
// CXX:      ::builtin::Nullable<signed int> find(signed int n);
// CXX:      signed int ptr( ::builtin::Nullable<signed int *> p);
// CXX:      return static_cast< ::builtin::Nullable<signed int>>(n);
// CXX:      return static_cast< ::builtin::Nullable<signed int>>( ::builtin::Nullable<signed int>( ::__kairo_vt<1> {
// CXX:      ::builtin::Nullable<decltype(sizeof(0))> __kairo_default_opt_x() {
// CXX:      return(c ? static_cast< ::builtin::Nullable<signed int>>(5): static_cast< ::builtin::Nullable<signed int>>( ::builtin::Nullable<signed int>( ::__kairo_vt<1> {
// CXX:      ::builtin::Nullable<signed int> a = static_cast< ::builtin::Nullable<signed int>>(5);
// CXX:      ::builtin::Nullable<signed int> u {
// CXX:      ::builtin::Nullable<{{ ?}}::builtin::Nullable<signed int>> nn =
// CXX:      ::builtin::Nullable<{{ ?}}::builtin::Nullable<signed int>> nested = static_cast<{{ ?}}::builtin::Nullable<{{ ?}}::builtin::Nullable<signed int>>>({{ ?}}ni);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out; test $? -eq 26
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      widgets
// OUT-NEXT: ~Widget 1
// OUT-NEXT: reassigned
// OUT-NEXT: ~Widget 2
// OUT-NEXT: cleared
// OUT-NEXT: ~Widget 3
// OUT-NEXT: taken
// OUT-NEXT: ~Widget 4
// OUT-NEXT: holder
// OUT-NEXT: ~Widget 5
// OUT-NEXT: ~Widget 6
// OUT-NEXT: ~Widget 7
// OUT-NEXT: done
// OUT-EMPTY:
