// A generic class that derives its own type parameter is a mixin over a base
// chosen at each use (classes-inheritance.mdx, Deriving a type parameter):
// `class <A derives Base> Hooked derives A`. Its body is checked once, against
// the bound: it reads the fields and calls the methods of `Base`, overrides a
// `virtual` of `Base`, and calls the base's own version either as `A::m(self)`
// (the argument's, an override included) or as `Base::m(self)` (the bound's).
// Each instance derives its argument: `Hooked<Other>` has Other's members and
// converts to `*Other` and `*Base`, virtual dispatch through a `*Base` reaches
// the mixin's override, `Hooked<Hooked<Other>>` stacks two, and a generic
// function over `Hooked<X>` sees what X's own bound promises. In C++ the
// class is `template <class A> class Hooked : public A`, a method it shares
// with the bound kept visible by `using A::plain;`.

import std::io

class Base {
    pub var n: i32 = 3
    pub fn Base(self) { }
    pub virtual fn begin(self) -> i32 { return 1 }
    pub virtual fn name(self) -> i32 { return 7 }
    pub fn plain(self) -> i32 { return self.n }
    pub fn plain(self, k: i32) -> i32 { return self.n + k }
    pub static fn make() -> i32 { return 40 }
}

class Other derives Base {
    pub var extra: i32 = 11
    pub fn Other(self) { self.n = 5 }
    pub override fn begin(self) -> i32 { return 10 }
    pub fn only_other(self) -> i32 { return self.extra }
}

class <A derives Base> Hooked derives A {
    pub var hook: i32 = 100
    pub override fn begin(self) -> i32 { return A::begin(self) + self.hook }
    pub fn via_bound(self) -> i32 { return Base::begin(self) }
    pub fn both(self) -> i32 { return self.plain() + self.plain(1) + self.n + A::make() }
    // Shares its name with the bound's two: all three stay callable.
    pub fn plain(self, a: i32, b: i32) -> i32 { return a + b }
}

fn through(b: *Base) -> i32 { return b->begin() + b->name() }

fn <X derives Base> twice(h: *Hooked<X>) -> i32 { return h->begin() + h->plain() }

fn main() -> i32 {
    var h = Hooked<Other>()
    var g = Hooked<Base>()
    var hh = Hooked<Hooked<Other>>()
    var o: *Other = &h
    io::println(f"other {h.begin()} {h.via_bound()} {h.both()} {h.plain()} {h.plain(2)} {h.plain(2, 3)}")
    io::println(f"argument {h.only_other()} {h.extra} {h.name()} {o->only_other()}")
    io::println(f"base {g.begin()} {g.both()} {g.plain(2, 3)}")
    io::println(f"dispatch {through(&h)} {through(&g)} {twice(&h)} {twice(&g)}")
    io::println(f"stacked {hh.begin()} {hh.hook} {through(&hh)} {hh.only_other()}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --match-full-lines < %t.out
// CHECK:      other 110 1 56 5 7 5
// CHECK-NEXT: argument 11 11 7 11
// CHECK-NEXT: base 101 50 5
// CHECK-NEXT: dispatch 117 108 115 104
// CHECK-NEXT: stacked 210 100 217 11
// RUN: { %kairo %s -c --cache-dir %t.d2 --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template<class A> class Hooked: public A {
// CXX: using A::plain;
// CXX: Hooked<A>::begin() noexcept {
// CXX-NEXT: {{.*}}A::begin()
// CXX: Hooked<A>::via_bound() noexcept {
// CXX-NEXT: {{.*}}::Base::begin()
