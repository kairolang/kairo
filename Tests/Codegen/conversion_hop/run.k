// A member `Buf` does not declare, found on the type one of its `@implicit
// op as` conversions yields, is called through that conversion. The
// conversion runs once per call: `conversions` counts 10 for the `self`
// conversion and 1 for the `const self` one, and each line prints the
// count the calls before it left.
//
// Covered: a method with arguments, a generic method and an extension
// member through the hop; a member `Buf` declares itself (`size`) wins; a
// mutable receiver takes the `self` conversion and falls back to the
// `const self` one for a member only its result has; a const receiver
// takes the `const self` one; `p->m()`, a field path and `self.m()` as
// receivers; a by-value parameter as the receiver; a generic body; an
// extension member of `Buf` winning over the result's; a conversion an
// extension declares; an infix operator the result declares, `!=` derived
// from it, and the type's own `op <=>` winning for `<`.

import std::io

var conversions: i32 = 0

class <T> View {
    pub var p: *T
    pub var n: usize
    pub fn View(self, p: *T, n: usize) { self.p = p; self.n = n }
    pub fn set0(self, v: T) { *self.p = v }
    pub fn size(const self) -> usize { return self.n + 100 }
    pub fn op == (const self, const o: View<T>) -> bool { return self.n == o.n }
    pub fn op < (const self, const o: View<T>) -> bool { return true }
    pub fn shadowed(const self) -> i32 { return 1 }
}

class <T> View<const T> {
    pub var p: *const T
    pub var n: usize
    pub fn View(self, p: *const T, n: usize) { self.p = p; self.n = n }
    pub fn only_const(const self) -> usize { return 7 }
}

extend <T> View<T> {
    pub fn first(const self) -> T { return *self.p }
    pub fn add(const self, a: usize, b: usize) -> usize { return self.n + a + b }
    pub fn <K> tag(const self, k: K) -> K { return k }
}

class <T> Buf {
    pub var x: T
    pub fn Buf(self, x: T) { self.x = x }
    pub fn size(const self) -> usize { return 1 }
    @implicit pub fn op as (const self) -> View<const T> {
        conversions += 1
        return View<const T>(const &self.x, 1)
    }

    @implicit pub fn op as (self) -> View<T> {
        conversions += 10
        return View<T>(&self.x, 1)
    }

    pub fn inside(self) -> T { return self.first() }
    pub fn inside_const(const self) -> T { return self.first() }
}

extend <T> Buf<T> {
    pub fn shadowed(const self) -> i32 { return 2 }
    pub fn op <=> (const self, const o: Buf<T>) -> Ordering {
        conversions += 1000
        return Ordering::Equal
    }
}

struct Raw {
    var x: i32
}

extend Raw {
    @implicit fn op as (self) -> View<i32> {
        conversions += 100
        return View<i32>(&self.x, 1)
    }
}

fn by_value(b: Buf<i32>) -> i32 { return b.first() }

class Holder {
    pub var b: Buf<i32>
    pub fn Holder(self) { self.b = Buf<i32>(3) }
}

fn <U> generic(b: Buf<U>, const c: Buf<U>) -> U {
    b.set0(c.first())
    return b.first()
}

fn main() -> i32 {
    var b = Buf<i32>(4)
    const c = Buf<i32>(5)
    var *p = &b
    var h = Holder()

    var own = b.size()
    io::println(f"{own} {conversions}")
    var f1 = b.first()
    io::println(f"{f1} {conversions}")
    var f2 = c.first()
    io::println(f"{f2} {conversions}")
    var a = b.add(1, 2)
    var t = b.tag(9)
    var u = c.tag(true)
    io::println(f"{a} {t} {u} {conversions}")
    b.set0(6)
    p->set0(b.x + 1)
    io::println(f"{b.x} {conversions}")
    var oc = b.only_const()
    io::println(f"{oc} {conversions}")
    var i1 = b.inside()
    var i2 = c.inside_const()
    io::println(f"{i1} {i2} {conversions}")
    var hf = h.b.first()
    io::println(f"{hf} {conversions}")
    var g = generic(b, c)
    io::println(f"{g} {b.x} {conversions}")
    var v = View<i32>(&b.x, 1)
    var eq = b == v
    io::println(f"{eq} {conversions}")
    var ne = b != v
    io::println(f"{ne} {conversions}")
    var lt = b < b
    io::println(f"{lt} {conversions}")
    var sh = b.shadowed()
    var r = Raw { x: 8 }
    var rf = r.first()
    io::println(f"{sh} {rf} {conversions}")
    var bv = by_value(b)
    io::println(f"{bv} {conversions}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// The conversion is written at the receiver, as the operator the receiver's
// constness selected.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: return{{.*}}::__kairo_ext_View::first<T>({{ ?}}::__kairo_tmp(this->operator{{.*}}::View<T>()));
// CXX: return{{.*}}::__kairo_ext_View::first<const T>({{ ?}}::__kairo_tmp(this->operator{{.*}}::View<const T>()));
// CXX: b.operator{{.*}}::View<U>()
// CXX: c.operator{{.*}}::View<const U>()
// CXX: b.size();
// CXX: ::__kairo_ext_View::first<signed int>({{ ?}}::__kairo_tmp(b.operator{{.*}}::View<signed int>()));
// CXX: ::__kairo_ext_View::first<const signed int>({{ ?}}::__kairo_tmp(c.operator{{.*}}::View<const signed int>()));
// CXX: b.operator{{.*}}::View<signed int>().set0(6);
// CXX: (* p).operator{{.*}}::View<signed int>()
// CXX: b.operator{{.*}}::View<const signed int>().only_const();
// CXX: h.b.operator{{.*}}::View<signed int>()

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT: 1 0
// OUT-NEXT: 4 10
// OUT-NEXT: 5 11
// OUT-NEXT: 4 9 true 32
// OUT-NEXT: 7 52
// OUT-NEXT: 7 53
// OUT-NEXT: 7 5 64
// OUT-NEXT: 3 74
// OUT-NEXT: 5 7 95
// OUT-NEXT: true 105
// OUT-NEXT: false 115
// OUT-NEXT: false 1115
// OUT-NEXT: 2 8 1215
// OUT-NEXT: 7 1225
